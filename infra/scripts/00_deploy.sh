#!/usr/bin/env bash
# =============================================================================
# End-to-end deployment - build the AWS infrastructure, then fill the cluster
# The mirror image of 07_undeploy.sh, and the executable form of README.md.
#
# Ordering is not a preference here. Each stage produces something the next one
# cannot start without:
#
#   S3 bucket        -> terraform init      backend must exist before init
#   terraform apply  -> everything else     cluster, RDS, ECR, IRSA roles
#   RDS + nodes      -> schema init         psql runs from a pod inside the VPC
#   ALB controller   -> Gateway + routes    no controller, no ALB address
#   ESO + IRSA       -> app pods            pods block on a missing Secret
#   CI pipelines     -> ArgoCD sync         Applications pull tags that must exist
#
# Values are discovered, not typed: terraform output first, AWS and git as the
# fallback. The only things asked for are the two Terraform secrets, and even
# those are recovered from Secrets Manager on a re-run.
#
# Safe to re-run: every step tolerates an already-present resource, so a run
# that dies part way is recovered by fixing the cause and running it again.
# =============================================================================
set -euo pipefail

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
ts() { date +%H:%M:%S; }
log()  { echo -e "${GREEN}[$(ts)] OK  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(ts)] !!  $*${NC}"; }
info() { echo -e "${CYAN}[$(ts)]     $*${NC}"; }
die()  { echo -e "${RED}[$(ts)] ERR $*${NC}" >&2; exit 1; }

TOTAL_STEPS=13
CURRENT_STEP=0
CURRENT_LABEL="startup"

step() {
  CURRENT_STEP="$1"; CURRENT_LABEL="$2"
  echo
  echo "--------------------------------------------"
  echo "  Step $1 of ${TOTAL_STEPS}: $2"
  echo "--------------------------------------------"
}

skipped_step() { info "Step $1 of ${TOTAL_STEPS} skipped: $2"; }

prompt() {
  local var="$1" label="$2" default="$3" current="${!1:-}"
  # Everything except the value itself goes to stderr - stdout is captured by
  # the caller's command substitution.
  if [ -n "$current" ]; then
    info "Using $var=$current  (pre-set)" >&2
    printf '%s' "$current"; return
  fi
  # No terminal, or running unattended: take the default rather than blocking.
  if ${ASSUME_YES:-false} || [ ! -r /dev/tty ]; then
    info "Using $var=$default  (default)" >&2
    printf '%s' "$default"; return
  fi
  echo >&2
  echo -e "${CYAN}  ${label}${NC}" >&2
  echo "    Default : ${default}" >&2
  read -r -p "    Your value [press Enter to use default]: " raw </dev/tty
  printf '%s' "${raw:-$default}"
}

# The Python installers ask for a final confirmation even when every value is
# already in the environment, so the answers are piped in. Only confirmations
# and menu choices reach them - the value prompts are all satisfied by exports.
answers() { printf '%s\n' "$@"; }

# JSON parsing without adding a jq dependency, matching 07_undeploy.sh.
# Absent, empty or non-JSON input yields an empty string: a secret that does
# not exist yet is an ordinary first-run state, not a stack trace.
json_get() {
  python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass
' "$1"
}

# Reads one field out of a Secrets Manager secret.
#   exit 0 - printed the value, or the secret genuinely does not exist yet
#   exit 3 - the secret is there but unreadable
# The split matters: treating a denied read as "not found" would generate a
# replacement password and rotate an RDS instance that is still using the old
# one. die() cannot be used here - inside $( ) it would only exit the subshell.
secret_field() {
  local secret_id="$1" field="$2" out rc=0
  out=$(aws secretsmanager get-secret-value --secret-id "$secret_id" \
    --region "$AWS_REGION" --query SecretString --output text 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *ResourceNotFoundException*) return 0 ;;
      *) return 3 ;;
    esac
  fi
  printf '%s' "$out" | json_get "$field"
}

# Approves every run parked on a deployment gate. 04 approves the runs it
# triggers itself, but only those - a run left waiting by an earlier invocation
# is invisible to it and would sit there forever, holding back the image tag
# the cluster needs. current_user_can_approve is false where the repository
# forbids self-review, and then no token of ours can clear it.
#
# Only the newest waiting run per workflow is approved. Two waiting runs of the
# same pipeline both write a tag into the same values file, and approving the
# older one too would race the newer and can leave that service pinned to the
# earlier image. gh lists newest first, so the first sighting wins.
approve_waiting_runs() {
  local repo="$1" runs id wf seen="" env_ids e approved=0
  runs=$(gh run list --repo "$repo" --branch "$BRANCH" --status waiting --limit 50 \
    --json databaseId,workflowName -q '.[] | "\(.databaseId)\t\(.workflowName)"' 2>/dev/null || true)
  if [ -z "$runs" ]; then
    info "No runs are waiting on a deployment approval."
    return 0
  fi
  while IFS=$'\t' read -r id wf; do
    [ -n "${id:-}" ] || continue
    case "$seen" in
      *"[${wf}]"*)
        warn "  run ${id}: superseded by a newer ${wf} run - left for you to cancel."
        continue ;;
    esac
    seen="${seen}[${wf}]"
    env_ids=$(gh api "repos/${repo}/actions/runs/${id}/pending_deployments" \
      -q '.[] | select(.current_user_can_approve) | .environment.id' 2>/dev/null || true)
    if [ -z "$env_ids" ]; then
      warn "  run ${id}: nothing this account may approve - a second reviewer must."
      continue
    fi
    local args=(gh api -X POST "repos/${repo}/actions/runs/${id}/pending_deployments")
    for e in $env_ids; do args+=(-F "environment_ids[]=${e}"); done
    args+=(-f state=approved -f "comment=Approved by 00_deploy.sh")
    if "${args[@]}" >/dev/null 2>&1; then
      log "  approved ${wf} (run ${id})"
      approved=$((approved + 1))
    else
      warn "  run ${id}: approval was rejected."
    fi
  done <<< "$runs"
  [ "$approved" -gt 0 ] && log "Cleared ${approved} deployment gate(s)." || true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for t in aws kubectl helm terraform python3 git openssl; do
  command -v "$t" >/dev/null || die "$t not found."
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${INFRA_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: 00_deploy.sh [options]

  --env <name>            Environment to deploy               (default: dev)
  --region <region>       AWS region                          (default: us-east-1)
  --github-org <org>      github_org var for terraform        (default: from git remote)
  --branch <name>         Branch the CI pipelines build       (default: develop)
  --skip-terraform        Use the existing infrastructure as-is
  --skip-pipeline         Do not trigger CI - images already in ECR
  --skip-github-secrets   Do not touch repository secrets or variables
  --yes                   Skip confirmations - for automation only
  -h, --help              Show this help

The state bucket is read from envs/<env>/backend.tf and created if missing.
The cluster name, VPC, RDS endpoint and IRSA role ARNs all come from Terraform
outputs, falling back to an AWS lookup when an output is not declared.

DB_PASSWORD and JWT_SECRET are taken from the environment. When unset they are
recovered from Secrets Manager, and generated only on a first run.

The CI deploy job is gated on the 'dev' GitHub Environment, which has a
required reviewer. That job is the one that writes new image tags into gitops,
so a run parked there would leave the cluster pulling the previous build. The
gate is approved over the API as the pipelines reach it, including any run left
waiting by an earlier invocation. This only works where self-review is allowed;
where it is not, the run is reported and a second reviewer has to act.

Every option also reads from an environment variable of the same name in
upper snake case, so these are equivalent:

  ./00_deploy.sh --env qa --region us-west-2
  ENV=qa AWS_REGION=us-west-2 ./00_deploy.sh

Flags win over environment variables, which win over the defaults above.

The steps:
   1 Preflight and AWS identity          8 Bootstrap ArgoCD
   2 Terraform state bucket              9 External Secrets and IRSA
   3 Resolve application secrets        10 GitHub Actions secrets
   4 Terraform init, plan, apply        11 CI pipelines - build images
   5 Outputs and cluster access         12 Deploy services via ArgoCD
   6 Database schemas                   13 Verify the deployment
   7 Cluster prerequisites

Examples:
  ./00_deploy.sh                              interactive, full deployment
  ./00_deploy.sh --yes                        unattended, full deployment
  ./00_deploy.sh --skip-terraform             the stack is up, bootstrap only
  ./00_deploy.sh --skip-terraform --skip-pipeline   redeploy from existing images
USAGE
}

ASSUME_YES=false
SKIP_TERRAFORM=false
SKIP_PIPELINE=false
SKIP_GITHUB_SECRETS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env)                  ENV="${2:?--env needs a value}"; shift 2 ;;
    --region)               AWS_REGION="${2:?--region needs a value}"; shift 2 ;;
    --github-org)           GH_ORG="${2:?--github-org needs a value}"; shift 2 ;;
    --branch)               BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --skip-terraform)       SKIP_TERRAFORM=true; shift ;;
    --skip-pipeline)        SKIP_PIPELINE=true; shift ;;
    --skip-github-secrets)  SKIP_GITHUB_SECRETS=true; shift ;;
    --yes|-y)               ASSUME_YES=true; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

# Every step tolerates an already-present resource, so the recovery for a
# half-finished run is to fix the cause and run the same command again. The
# completed steps cost seconds: plan reports no changes, the bucket exists,
# and the secrets come back out of Secrets Manager.
on_err() {
  local rc=$?
  echo
  echo -e "${RED}[$(ts)] ERR Step ${CURRENT_STEP} failed (${CURRENT_LABEL}) - exit ${rc}.${NC}" >&2
  echo -e "${YELLOW}[$(ts)] !!  Fix the cause above, then run the same command again.${NC}" >&2
  exit "$rc"
}
trap on_err ERR

START_TIME=$(date +%s)

echo
echo "============================================"
echo "  Pharmacy -- Deployment"
echo "============================================"
echo
echo "  Provisions the VPC, EKS cluster, RDS instance and ECR repositories,"
echo "  then installs the platform charts and deploys the application."
echo "  A first run takes roughly 45 minutes, most of it EKS and RDS."
echo

ENV=$(prompt ENV "Environment to deploy" "dev")
AWS_REGION=$(prompt AWS_REGION "AWS region" "us-east-1")
export ENV AWS_REGION

ENV_DIR="${INFRA_DIR}/envs/${ENV}"
[ -d "$ENV_DIR" ] || die "No Terraform environment at ${ENV_DIR}"

BRANCH="${BRANCH:-develop}"
MENU_CHOICE_ALL_SERVICES=A

# ---------------------------------------------------------------------------
step 1 "Preflight and AWS identity"
# ---------------------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "AWS credentials are not working. Run 'aws configure' first."
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown")
log "Authenticated as ${CALLER_ARN}"
info "Account        : ${ACCOUNT_ID}"

# backend.tf is the only place that decides where state lives, so a default
# here could silently point the deployment at the wrong bucket.
if [ -z "${TF_STATE_BUCKET:-}" ]; then
  TF_STATE_BUCKET=$(/usr/bin/sed -n 's/.*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${ENV_DIR}/backend.tf" 2>/dev/null | head -1)
fi
[ -n "$TF_STATE_BUCKET" ] || die "Could not read the bucket name from ${ENV_DIR}/backend.tf"
case "$TF_STATE_BUCKET" in
  *YOUR-GITHUB-USERNAME*|*your-github-username*)
    die "${ENV_DIR}/backend.tf still has the placeholder bucket name.
     Bucket names are globally unique - edit it to something of your own first." ;;
esac
info "State bucket   : ${TF_STATE_BUCKET}  (from backend.tf)"

# The lock object sits next to the state file, so its path follows whatever key
# backend.tf declares. Assuming the envs/<env>/ convention would silently miss
# the real lock on a fork that renamed it.
TF_STATE_KEY=$(/usr/bin/sed -n 's/.*key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "${ENV_DIR}/backend.tf" 2>/dev/null | head -1)
[ -n "$TF_STATE_KEY" ] || TF_STATE_KEY="envs/${ENV}/terraform.tfstate"

# Terraform pins its own provider region in providers.tf and ignores anything
# passed here, so a mismatch would apply to one region while every AWS and
# kubectl lookup below searched another.
PROVIDER_REGION=$(/usr/bin/sed -n '/provider "aws"/,/^}/s/^[[:space:]]*region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "${ENV_DIR}/providers.tf" 2>/dev/null | head -1)
if [ -n "$PROVIDER_REGION" ] && [ "$PROVIDER_REGION" != "$AWS_REGION" ]; then
  die "Region mismatch: you asked for ${AWS_REGION}, but ${ENV_DIR}/providers.tf
     pins the AWS provider to ${PROVIDER_REGION}. Terraform would build the stack
     in ${PROVIDER_REGION} while this script looked for it in ${AWS_REGION}.
     Edit providers.tf, or re-run with --region ${PROVIDER_REGION}."
fi

if [ -z "${GH_ORG:-}" ]; then
  GH_ORG=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | /usr/bin/sed -E 's#.*[:/]([^/]+)/[^/]+(\.git)?$#\1#' || true)
  [ -n "$GH_ORG" ] || GH_ORG="gulywwx"
fi
# 02 and 05 ask for a "personal GitHub username, not the organization name".
# The distinction only matters on a real org account; here the remote owner is
# the user, so one value serves both and there is nothing extra to get wrong.
GITHUB_USERNAME="$GH_ORG"
REPO_NAME=$(basename -s .git "$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo gitops)")
GITOPS_REPO_URL="${GITOPS_REPO_URL:-https://github.com/${GH_ORG}/${REPO_NAME}.git}"
GITOPS_PATH="${GITOPS_PATH:-${REPO_ROOT}/gitops}"
[ -d "$GITOPS_PATH" ] || die "No gitops manifests at ${GITOPS_PATH}"
info "GitHub org     : ${GH_ORG}"
info "GitOps repo    : ${GITOPS_REPO_URL}  (branch ${BRANCH})"

CLUSTER_NAME="${CLUSTER_NAME:-pharma-${ENV}-cluster}"

echo
echo "  ----- About to deploy -----"
echo "  AWS account : ${ACCOUNT_ID}"
echo "  Region      : ${AWS_REGION}"
echo "  Environment : ${ENV}"
echo "  Cluster     : ${CLUSTER_NAME}"
echo "  Terraform   : ${ENV_DIR}"
echo "  ---------------------------"
echo
if $ASSUME_YES; then
  warn "--yes given - skipping the confirmation prompt."
elif [ -r /dev/tty ]; then
  read -r -p "  Type 'deploy' to confirm: " CONFIRM </dev/tty
  [ "$CONFIRM" = "deploy" ] || die "Aborted."
fi

# ---------------------------------------------------------------------------
step 2 "Terraform state bucket"
# ---------------------------------------------------------------------------
# Terraform never creates its own backend, so this has to exist before init.
if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
  log "Bucket ${TF_STATE_BUCKET} already exists."
else
  info "Creating ${TF_STATE_BUCKET} in ${AWS_REGION}..."
  # us-east-1 is the API's default and rejects an explicit LocationConstraint.
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region us-east-1 >/dev/null \
      || die "Could not create ${TF_STATE_BUCKET}. Bucket names are globally unique - pick another in ${ENV_DIR}/backend.tf."
  else
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null \
      || die "Could not create ${TF_STATE_BUCKET}. Bucket names are globally unique - pick another in ${ENV_DIR}/backend.tf."
  fi
  log "Bucket created."
fi

# Re-applied every run, because a bucket created by hand from an older README
# may predate these settings. Versioning is the only thing standing between a
# stray `aws s3 rm` and a state file nobody can get back.
aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled >/dev/null
aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
log "Versioning, encryption and public access block confirmed."

# ---------------------------------------------------------------------------
step 3 "Resolve application secrets"
# ---------------------------------------------------------------------------
# Regenerating these on a re-run would rewrite the RDS master password and
# invalidate every token already issued, so an existing value always wins.
DB_SECRET_ID="/pharma/${ENV}/db-credentials"
JWT_SECRET_ID="/pharma/${ENV}/jwt-secret"

if [ -n "${DB_PASSWORD:-}" ]; then
  info "DB password    : from the environment"
else
  SECRET_RC=0
  DB_PASSWORD=$(secret_field "$DB_SECRET_ID" password) || SECRET_RC=$?
  [ "$SECRET_RC" -eq 3 ] && die "${DB_SECRET_ID} exists but could not be read.
     Generating a replacement would rotate the RDS master password away from the
     one the running instance uses. Fix the access, or export DB_PASSWORD."
  if [ -n "$DB_PASSWORD" ]; then
    info "DB password    : recovered from ${DB_SECRET_ID}"
  else
    # hex only - RDS rejects '/', '@', '"' and spaces in a master password.
    DB_PASSWORD=$(openssl rand -hex 16)
    GENERATED_DB=true
    warn "DB password    : generated (no existing secret found)"
  fi
fi

if [ -n "${JWT_SECRET:-}" ]; then
  info "JWT secret     : from the environment"
else
  SECRET_RC=0
  JWT_SECRET=$(secret_field "$JWT_SECRET_ID" secret) || SECRET_RC=$?
  [ "$SECRET_RC" -eq 3 ] && die "${JWT_SECRET_ID} exists but could not be read.
     Generating a replacement would invalidate every token already issued.
     Fix the access, or export JWT_SECRET."
  if [ -n "$JWT_SECRET" ]; then
    info "JWT secret     : recovered from ${JWT_SECRET_ID}"
  else
    # auth-service signs with HMAC-SHA and jjwt rejects keys under 256 bits.
    JWT_SECRET=$(openssl rand -hex 32)
    GENERATED_JWT=true
    warn "JWT secret     : generated (no existing secret found)"
  fi
fi

if [ ${#JWT_SECRET} -lt 32 ]; then
  die "JWT_SECRET is ${#JWT_SECRET} characters. jjwt rejects anything under 256 bits
     at the first login, long after a clean apply. Use: openssl rand -hex 32"
fi
if [ ${#DB_PASSWORD} -lt 8 ]; then
  die "DB_PASSWORD is ${#DB_PASSWORD} characters - RDS requires at least 8."
fi

if [ "${GENERATED_DB:-false}" = true ] || [ "${GENERATED_JWT:-false}" = true ]; then
  # Nothing here writes to Secrets Manager - the secrets-manager module does,
  # during the apply in step 4. Until that succeeds these values live only in
  # this shell, so a run that dies before it generates different ones next time.
  if $SKIP_TERRAFORM; then
    die "Generated a new DB_PASSWORD/JWT_SECRET, but --skip-terraform means nothing
     will store them, and the running stack already uses different values.
     Export the real DB_PASSWORD and JWT_SECRET, or drop --skip-terraform."
  fi
  echo
  warn "  Save these now - the apply in step 4 writes them to Secrets Manager,"
  warn "  and nothing writes them to disk:"
  [ "${GENERATED_DB:-false}"  = true ] && warn "    DB_PASSWORD=${DB_PASSWORD}" || true
  [ "${GENERATED_JWT:-false}" = true ] && warn "    JWT_SECRET=${JWT_SECRET}" || true
  echo
fi
log "Secrets resolved."

# ---------------------------------------------------------------------------
if ! $SKIP_TERRAFORM; then
  step 4 "Terraform init, plan and apply"
  # -------------------------------------------------------------------------
  # A cancelled run leaves a lock file that blocks every future apply.
  aws s3 rm "s3://${TF_STATE_BUCKET}/${TF_STATE_KEY}.tflock" >/dev/null 2>&1 \
    && warn "Cleared a stranded state lock." || true

  cd "$ENV_DIR"
  terraform init -input=false >/dev/null || die "terraform init failed."
  log "Backend initialised against ${TF_STATE_BUCKET}."

  terraform validate >/dev/null || die "terraform validate failed."
  log "Configuration is valid."

  TF_VARS=(
    -var "db_password=${DB_PASSWORD}"
    -var "jwt_secret=${JWT_SECRET}"
    -var "github_org=${GH_ORG}"
  )

  # -detailed-exitcode: 0 no changes, 2 changes pending, 1 error. Distinguishing
  # the first two is what makes a re-run cheap instead of a 20 minute no-op.
  info "Planning..."
  PLAN_RC=0
  terraform plan -input=false -detailed-exitcode -out=tfplan "${TF_VARS[@]}" || PLAN_RC=$?

  case "$PLAN_RC" in
    0) log "Infrastructure already matches the configuration - nothing to apply." ;;
    2)
      echo
      if $ASSUME_YES; then
        warn "--yes given - applying without confirmation."
      elif [ -r /dev/tty ]; then
        read -r -p "  Apply this plan? [y/N]: " GO </dev/tty
        [[ "${GO:-N}" =~ ^[Yy]$ ]] || die "Aborted - nothing was changed."
      fi
      info "Applying. EKS takes ~10m, the node group ~5m, RDS ~5m. Do not cancel."
      APPLY_START=$(date +%s)
      terraform apply -input=false tfplan \
        || die "terraform apply failed. Terraform records every resource it did
     create, so fixing the cause and re-running continues where it stopped."
      log "Apply finished in $(( ($(date +%s) - APPLY_START) / 60 ))m."
      ;;
    *) die "terraform plan failed." ;;
  esac
  rm -f tfplan
else
  skipped_step 4 "Terraform init, plan and apply"
  cd "$ENV_DIR"
  terraform init -input=false >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
step 5 "Terraform outputs and cluster access"
# ---------------------------------------------------------------------------
# Always runs: later steps need these values whether or not step 4 was skipped.
cd "$ENV_DIR"
tf_out() { terraform output -raw "$1" 2>/dev/null || true; }

RDS_ENDPOINT_RAW=$(tf_out rds_endpoint)
TF_CLUSTER_NAME=$(tf_out eks_cluster_name)
VPC_ID=$(tf_out vpc_id)
ALB_CONTROLLER_ROLE=$(tf_out alb_controller_role_arn)
ESO_ROLE_ARN=$(tf_out eso_role_arn)
BASE_DOMAIN=$(tf_out internal_domain)
ACM_CERTIFICATE_ARN=$(tf_out acm_certificate_arn)

[ -n "$TF_CLUSTER_NAME" ] && CLUSTER_NAME="$TF_CLUSTER_NAME"

# 01 can auto-detect the VPC, but only from inside a prompt that would first
# swallow the confirmation piped into it - one prompt too many, and every
# later answer lands on the wrong question. Resolving it here keeps the pipe
# aligned: exactly one question reaches the script, and it gets the Y.
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)
  [ "$VPC_ID" = "None" ] && VPC_ID=""
  [ -n "$VPC_ID" ] && info "VPC found via AWS lookup." || true
fi

# qa and prod do not declare the three IRSA outputs that dev does, and a state
# file from before they were added will not have them either. Ask AWS instead.
if [ -z "$ALB_CONTROLLER_ROLE" ]; then
  ALB_CONTROLLER_ROLE=$(aws iam list-roles \
    --query "Roles[?contains(RoleName,'pharma-${ENV}-alb-controller')].Arn|[0]" \
    --output text 2>/dev/null || true)
  [ "$ALB_CONTROLLER_ROLE" = "None" ] && ALB_CONTROLLER_ROLE=""
  [ -n "$ALB_CONTROLLER_ROLE" ] && info "ALB role found via AWS lookup."
fi
[ -n "$ALB_CONTROLLER_ROLE" ] \
  || ALB_CONTROLLER_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/pharma-${ENV}-alb-controller-role"

if [ -z "$ESO_ROLE_ARN" ]; then
  ESO_ROLE_ARN=$(aws iam list-roles \
    --query "Roles[?contains(RoleName,'pharma-${ENV}-eso')].Arn|[0]" \
    --output text 2>/dev/null || true)
  [ "$ESO_ROLE_ARN" = "None" ] && ESO_ROLE_ARN=""
fi
[ -n "$ESO_ROLE_ARN" ] || ESO_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/pharma-${ENV}-eso-role"
# 03_setup_external_secrets.py rebuilds the ARN from the account and the name.
ESO_ROLE_NAME="${ESO_ROLE_ARN##*/}"

[ -n "$BASE_DOMAIN" ] || BASE_DOMAIN="pharma.internal"

if [ -z "$ACM_CERTIFICATE_ARN" ]; then
  ACM_CERTIFICATE_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='*.${BASE_DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)
  [ "$ACM_CERTIFICATE_ARN" = "None" ] && ACM_CERTIFICATE_ARN=""
  [ -n "$ACM_CERTIFICATE_ARN" ] && info "ACM certificate found via AWS lookup." || true
fi
if [ -z "$ACM_CERTIFICATE_ARN" ]; then
  warn "No ACM certificate for *.${BASE_DOMAIN} - the Gateway's HTTPS listener"
  warn "cannot be configured and ${ENV}.${BASE_DOMAIN} will not serve TLS."
  warn "Import a certificate, or re-run once terraform declares acm_certificate_arn."
fi

if [ -z "$RDS_ENDPOINT_RAW" ]; then
  RDS_ENDPOINT_RAW=$(aws rds describe-db-instances --region "$AWS_REGION" \
    --query "DBInstances[?contains(DBInstanceIdentifier,'pharma-${ENV}')].Endpoint.Address|[0]" \
    --output text 2>/dev/null || true)
  [ "$RDS_ENDPOINT_RAW" = "None" ] && RDS_ENDPOINT_RAW=""
fi
# rds_endpoint is host:port, and psql -h chokes on the port being glued on.
RDS_ENDPOINT="${RDS_ENDPOINT_RAW%%:*}"

aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
  || die "Cluster ${CLUSTER_NAME} not found in ${AWS_REGION}. Run without --skip-terraform first."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null \
  || die "Could not write a kubeconfig entry for ${CLUSTER_NAME}."
kubectl get nodes >/dev/null 2>&1 \
  || die "Cluster ${CLUSTER_NAME} is unreachable. Check that your IAM identity has cluster access."

info "Waiting for every node to report Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=10m >/dev/null \
  || warn "Not every node is Ready - continuing, but pods may stay Pending."
kubectl get nodes --no-headers 2>/dev/null | awk '{print "     node " $1 " " $2}'

echo
info "Cluster        : ${CLUSTER_NAME}"
info "VPC            : ${VPC_ID:-<none found>}"
info "RDS            : ${RDS_ENDPOINT:-<none found>}"
info "ALB role       : ${ALB_CONTROLLER_ROLE}"
info "ESO role       : ${ESO_ROLE_NAME}"
info "Domain         : ${BASE_DOMAIN}"
info "ACM cert       : ${ACM_CERTIFICATE_ARN:-<none found>}"
log "Cluster access confirmed."

# All three environments are created, not just the one being deployed. The
# pharma AppProject already whitelists dev, qa and prod as destinations, and an
# ArgoCD Application cannot sync into a namespace that does not exist yet. They
# cost nothing empty, and it keeps a later --env qa from needing this step.
for ns in dev qa prod; do
  # A namespace still draining from a teardown cannot be recreated - the apply
  # is rejected outright rather than queued behind the deletion.
  if [ "$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Terminating" ]; then
    info "Namespace '${ns}' is still terminating - waiting for it to clear..."
    NS_DEADLINE=$(( $(date +%s) + 180 ))
    while [ "$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Terminating" ]; do
      if [ "$(date +%s)" -ge "$NS_DEADLINE" ]; then
        die "Namespace '${ns}' is wedged in Terminating after 3 minutes. Something
     still holds a finalizer on it. Inspect with:
       kubectl get ns ${ns} -o jsonpath='{.spec.finalizers}'
       kubectl api-resources --verbs=list --namespaced -o name \\
         | xargs -n1 kubectl get -n ${ns} --ignore-not-found"
      fi
      sleep 5
    done
  fi

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    env: ${ns}
    managed-by: 00_deploy.sh
EOF
  log "Namespace '${ns}' ready."
done

# Exported once here so the Python installers skip their value prompts. What
# remains is confirmations only, which `answers` feeds on stdin.
export CLUSTER_NAME AWS_REGION VPC_ID ALB_CONTROLLER_ROLE
export GITOPS_PATH GITOPS_REPO_URL GITHUB_USERNAME
export AWS_ACCOUNT_ID="$ACCOUNT_ID"
export ESO_ROLE_NAME
export BASE_DOMAIN ACM_CERTIFICATE_ARN
export GITHUB_ORG="$GH_ORG" REPO="$REPO_NAME" BRANCH
export RDS_ENDPOINT DB_PASSWORD NAMESPACE="$ENV"

# ---------------------------------------------------------------------------
step 6 "Initialize the database schemas"
# ---------------------------------------------------------------------------
# RDS sits in a private subnet, so the SQL runs from a throwaway pod inside
# the VPC. The schemas are CREATE ... IF NOT EXISTS, hence safe to repeat.
if [ -z "$RDS_ENDPOINT" ]; then
  warn "No RDS endpoint resolved - skipping schema initialization."
else
  answers Y | bash "${SCRIPT_DIR}/init-database.sh" \
    || die "Schema initialization failed. Check that the node group can reach
     ${RDS_ENDPOINT} on 5432."
  log "Database schemas initialized."
fi

# ---------------------------------------------------------------------------
step 7 "Cluster prerequisites - ALB controller, ArgoCD, ESO"
# ---------------------------------------------------------------------------
[ -n "$VPC_ID" ] || die "No VPC resolved for ${CLUSTER_NAME}. Continuing would leave
     01_install_prerequisites.py asking for it, and the answers fed to it from
     here would then line up against the wrong questions."
answers Y | python3 "${SCRIPT_DIR}/01_install_prerequisites.py"
log "Platform charts installed."

# ---------------------------------------------------------------------------
step 8 "Bootstrap ArgoCD - repository and AppProject"
# ---------------------------------------------------------------------------
# 02 reads the token with getpass, which blocks on /dev/tty and cannot be fed
# from a pipe. Resolving it here is what keeps an unattended run unattended.
if [ -z "${GITOPS_TOKEN:-}" ]; then
  GITOPS_TOKEN=$(gh auth token 2>/dev/null || true)
  [ -n "$GITOPS_TOKEN" ] && info "GitOps token   : borrowed from the gh CLI session" || true
fi
if [ -z "$GITOPS_TOKEN" ]; then
  if $ASSUME_YES || [ ! -r /dev/tty ]; then
    die "GITOPS_TOKEN is unset and gh is not logged in. ArgoCD needs a PAT with
     read access to ${GITOPS_REPO_URL}. Export GITOPS_TOKEN, or run 'gh auth login'."
  fi
  echo
  echo -e "${CYAN}  GitHub PAT with read access to the gitops repo${NC}" >&2
  read -r -s -p "    Token (input is hidden): " GITOPS_TOKEN </dev/tty
  echo
  [ -n "$GITOPS_TOKEN" ] || die "A token is required to register the repository."
fi
export GITOPS_TOKEN

answers Y | python3 "${SCRIPT_DIR}/02_bootstrap_argocd.py"
log "ArgoCD knows the repository and the pharma AppProject."

# ---------------------------------------------------------------------------
step 9 "External Secrets - IRSA and ClusterSecretStore"
# ---------------------------------------------------------------------------
answers Y | python3 "${SCRIPT_DIR}/03_setup_external_secrets.py"
log "Secrets Manager is wired into namespace '${ENV}'."

# ---------------------------------------------------------------------------
if ! $SKIP_GITHUB_SECRETS; then
  step 10 "GitHub Actions secrets and variables"
  # -------------------------------------------------------------------------
  # Step 11 triggers workflows that authenticate to AWS and write image tags
  # back to this repo. Without these they fail on the first job, minutes in.
  if ! command -v gh >/dev/null; then
    warn "gh CLI not installed - skipping. Set the secrets by hand per README section 5."
  elif ! gh auth status >/dev/null 2>&1; then
    warn "gh CLI is not authenticated - skipping. Run 'gh auth login' first."
  else
    GH_REPO="${GH_ORG}/${REPO_NAME}"
    EXISTING_SECRETS=$(gh secret list --repo "$GH_REPO" 2>/dev/null | awk '{print $1}' || true)
    EXISTING_VARS=$(gh variable list --repo "$GH_REPO" 2>/dev/null | awk '{print $1}' || true)

    has() { echo "$2" | grep -qx "$1"; }

    set_secret_if_absent() {
      local name="$1" value="$2"
      if [ -z "$value" ]; then
        warn "  ${name}: no value available - set it by hand."
      elif has "$name" "$EXISTING_SECRETS"; then
        info "  ${name}: already set - left alone."
      else
        printf '%s' "$value" | gh secret set "$name" --repo "$GH_REPO" >/dev/null 2>&1 \
          && log "  ${name}: set." || warn "  ${name}: could not be set - admin rights needed."
      fi
    }

    set_var_if_absent() {
      local name="$1" value="$2"
      if has "$name" "$EXISTING_VARS"; then
        info "  ${name}: already set - left alone."
      else
        gh variable set "$name" --repo "$GH_REPO" --body "$value" >/dev/null 2>&1 \
          && log "  ${name}: set." || warn "  ${name}: could not be set - admin rights needed."
      fi
    }

    # These two are overwritten rather than preserved: they are what Terraform
    # just applied, so a stale repository secret would plan a password change
    # on the next CI run. The names are per-environment - writing DEV_* from a
    # qa run would hand qa's password to the dev pipeline.
    ENV_UPPER=$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')
    for pair in "${ENV_UPPER}_DB_PASSWORD:${DB_PASSWORD}" "${ENV_UPPER}_JWT_SECRET:${JWT_SECRET}"; do
      name="${pair%%:*}"; value="${pair#*:}"
      printf '%s' "$value" | gh secret set "$name" --repo "$GH_REPO" >/dev/null 2>&1 \
        && log "  ${name}: synced with the applied infrastructure." \
        || warn "  ${name}: could not be set - admin rights needed."
    done

    AWS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || true)
    AWS_KEY_SECRET=$(aws configure get aws_secret_access_key 2>/dev/null || true)
    if [ -z "$AWS_KEY_ID" ]; then
      warn "  AWS_ACCESS_KEY_ID: no static key in the AWS profile (SSO or a role?)."
      warn "                     CI needs a static key - add it by hand."
    fi
    set_secret_if_absent AWS_ACCESS_KEY_ID     "$AWS_KEY_ID"
    set_secret_if_absent AWS_SECRET_ACCESS_KEY "$AWS_KEY_SECRET"
    set_secret_if_absent AWS_ACCOUNT_ID        "$ACCOUNT_ID"
    set_secret_if_absent GITOPS_TOKEN          "${GITOPS_TOKEN:-}"

    set_var_if_absent GH_ORG          "$GH_ORG"
    set_var_if_absent TF_STATE_BUCKET "$TF_STATE_BUCKET"
    set_var_if_absent GITOPS_REPO     "$GH_REPO"

    # The SonarCloud step warns and skips rather than failing, so these stay
    # manual - there is no way to mint the token from here.
    has SONAR_TOKEN "$EXISTING_SECRETS" \
      || warn "  SONAR_TOKEN unset - SonarCloud scanning will be skipped in CI."
  fi
else
  skipped_step 10 "GitHub Actions secrets and variables"
fi

# ---------------------------------------------------------------------------
if ! $SKIP_PIPELINE; then
  step 11 "CI pipelines - build images and push to ECR"
  # -------------------------------------------------------------------------
  # ArgoCD syncs whatever tag the gitops manifests name. Deploying before the
  # pipelines have pushed that tag leaves every pod in ImagePullBackOff.
  if ! command -v gh >/dev/null; then
    die "gh CLI not found. Install it from https://cli.github.com/ and run
     'gh auth login', or pass --skip-pipeline if the images are already built."
  fi
  gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated. Run: gh auth login"

  approve_waiting_runs "${GH_ORG}/${REPO_NAME}"

  answers "$MENU_CHOICE_ALL_SERVICES" Y | python3 "${SCRIPT_DIR}/04_run_pipeline.py" \
    || die "Not every pipeline finished. Deploying now would sync manifests that
     still name the previous build, and every pod would land in ImagePullBackOff.
     Read the run logs linked above - a build that fails its tests or its image
     push cannot be approved past, it has to be fixed."
  log "Images built and image tags committed to the gitops repo."
else
  skipped_step 11 "CI pipelines"
fi

# ---------------------------------------------------------------------------
step 12 "Deploy services via ArgoCD"
# ---------------------------------------------------------------------------
answers "$MENU_CHOICE_ALL_SERVICES" Y | python3 "${SCRIPT_DIR}/05_deploy_services.py"
log "ArgoCD Applications applied."

# ---------------------------------------------------------------------------
step 13 "Verify the deployment"
# ---------------------------------------------------------------------------
# 06 exits with the number of failed checks. Letting that abort the run would
# hide the summary below, which is where the URLs and credentials are.
VERIFY_RC=0
python3 "${SCRIPT_DIR}/06_verify_deployment.py" || VERIFY_RC=$?

# ---------------------------------------------------------------------------
CURRENT_LABEL="summary"
echo
echo "============================================"
echo "  Pharmacy -- Deployment Summary"
echo "============================================"
# ---------------------------------------------------------------------------
ALB_HOSTNAME=$(kubectl get gateway pharma-gateway -n gateway-system \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

echo
echo "  AWS account   : ${ACCOUNT_ID}"
echo "  Region        : ${AWS_REGION}"
echo "  Environment   : ${ENV}"
echo "  Cluster       : ${CLUSTER_NAME}"
echo "  Database      : ${RDS_ENDPOINT:-<none>}"
echo
echo "  Application   : https://${ENV}.${BASE_DOMAIN}/"
echo "  ArgoCD UI     : https://argocd.${BASE_DOMAIN}"
if [ -n "$ALB_HOSTNAME" ]; then
  echo "  Gateway ALB   : ${ALB_HOSTNAME}"
  # The domain is not registered anywhere - it resolves only from /etc/hosts,
  # and the ALB answers on an IP that changes, so the entry is printed fresh.
  ALB_IP=$(dig +short "$ALB_HOSTNAME" 2>/dev/null | head -1 || true)
  echo
  echo "  Add to /etc/hosts:"
  if [ -n "$ALB_IP" ]; then
    echo "    ${ALB_IP}  ${ENV}.${BASE_DOMAIN} argocd.${BASE_DOMAIN}"
  else
    echo "    <resolve ${ALB_HOSTNAME} yourself - dig returned nothing yet>  ${ENV}.${BASE_DOMAIN} argocd.${BASE_DOMAIN}"
  fi
else
  echo "  Gateway ALB   : no address yet - the controller may still be"
  echo "                  provisioning. Check: kubectl get gateway pharma-gateway -n gateway-system"
fi
echo
echo "  ArgoCD port-fw: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "                  https://localhost:8080"
echo "  ArgoCD login  : admin / ${ARGOCD_PASSWORD:-<already rotated - see your notes>}"
echo
echo "  Tear it down  : ${SCRIPT_DIR}/07_undeploy.sh --env ${ENV}"
echo

ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
if [ "$VERIFY_RC" -eq 0 ]; then
  log "Deployment finished in ${ELAPSED}m."
else
  warn "Deployment finished in ${ELAPSED}m with ${VERIFY_RC} failing check(s)."
  warn "The stack is up but not yet healthy. Re-run the checks once ArgoCD"
  warn "settles:  ENV=${ENV} python3 ${SCRIPT_DIR}/06_verify_deployment.py"
fi
echo
exit "$VERIFY_RC"
