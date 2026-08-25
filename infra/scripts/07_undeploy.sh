#!/usr/bin/env bash
# =============================================================================
# Teardown - drain the cluster, then destroy the AWS infrastructure
# Follows documents/RUNBOOK-DESTROY.md
#
# Terraform does not track what Kubernetes provisions in AWS:
#
#   Ingress             -> ALB            VPC delete fails (subnet ENIs)
#   Service type=LB     -> NLB / CLB      VPC delete fails (subnet ENIs)
#   PersistentVolume    -> EBS volume     survives, still billed
#   TargetGroupBinding  -> target group   namespace hangs in Terminating
#
# The VPC case fails late, after EKS and RDS are gone, leaving a half-destroyed
# stack. So each class is drained and confirmed gone with AWS before Terraform.
#
# Safe to re-run: every step tolerates an already-absent resource.
# =============================================================================
set -euo pipefail

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
ts() { date +%H:%M:%S; }
log()  { echo -e "${GREEN}[$(ts)] OK  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(ts)] !!  $*${NC}"; }
info() { echo -e "${CYAN}[$(ts)]     $*${NC}"; }
die()  { echo -e "${RED}[$(ts)] ERR $*${NC}" >&2; exit 1; }

step() {
  echo
  echo "--------------------------------------------"
  echo "  $*"
  echo "--------------------------------------------"
}

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

# Kubernetes helpers no-op once the cluster is unreachable, so a resumed run
# does not abort on the first kubectl call.
CLUSTER_UP=false
k() { $CLUSTER_UP || return 0; kubectl "$@" 2>/dev/null || true; }
kq() { $CLUSTER_UP || return 0; kubectl "$@" 2>/dev/null || true; }

# Namespaces the stack owns. kube-system is handled separately - it holds the
# ALB controller but must not itself be deleted.
APP_NAMESPACES="dev qa prod"
ALL_NAMESPACES="dev qa prod argocd external-secrets"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for t in aws kubectl helm terraform python3; do
  command -v "$t" >/dev/null || die "$t not found."
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: 07_undeploy.sh [options]

  --env <name>            Environment to destroy            (default: dev)
  --region <region>       AWS region                        (default: us-east-1)
  --github-org <org>      github_org var for terraform      (default: from git remote)
  --delete-state-bucket   Also delete the state bucket      (default: keep it)
  --yes                   Skip confirmations - for automation only
  -h, --help              Show this help

The cluster name and state bucket are derived: the bucket is read from
envs/<env>/backend.tf, the cluster is looked up in the region.

Every option also reads from an environment variable of the same name in
upper snake case, so these are equivalent:

  ./07_undeploy.sh --env qa --region us-west-2
  ENV=qa AWS_REGION=us-west-2 ./07_undeploy.sh

Flags win over environment variables, which win over the defaults above.

Examples:
  ./07_undeploy.sh                                  interactive, keeps the bucket
  ./07_undeploy.sh --env dev --delete-state-bucket  interactive, removes the bucket
  ./07_undeploy.sh --env dev --yes                  unattended
USAGE
}

ASSUME_YES=false
DELETE_STATE_BUCKET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env)                  ENV="${2:?--env needs a value}"; shift 2 ;;
    --region)               AWS_REGION="${2:?--region needs a value}"; shift 2 ;;
    --github-org)           GH_ORG="${2:?--github-org needs a value}"; shift 2 ;;
    --delete-state-bucket)  DELETE_STATE_BUCKET=true; shift ;;
    --yes|-y)               ASSUME_YES=true; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done
export ENV AWS_REGION GH_ORG

echo
echo "============================================"
echo "  Zen Pharma -- Teardown"
echo "============================================"
echo
echo "  Drains every AWS-backed Kubernetes resource, then destroys the EKS"
echo "  cluster, RDS instance, VPC and ECR repositories."
echo "  The RDS data is not recoverable."
echo

ENV=$(prompt ENV "Environment to destroy" "dev")
AWS_REGION=$(prompt AWS_REGION "AWS region" "us-east-1")

ENV_DIR="${INFRA_DIR}/envs/${ENV}"
[ -d "$ENV_DIR" ] || die "No Terraform environment at ${ENV_DIR}"

# backend.tf is the only place that actually decides where state lives, so a
# default here could silently point the purge at the wrong bucket.
if [ -z "${TF_STATE_BUCKET:-}" ]; then
  TF_STATE_BUCKET=$(/usr/bin/sed -n 's/.*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${ENV_DIR}/backend.tf" 2>/dev/null | head -1)
fi
[ -n "$TF_STATE_BUCKET" ] || die "Could not read the bucket name from ${ENV_DIR}/backend.tf"
case "$TF_STATE_BUCKET" in
  *YOUR-GITHUB-USERNAME*|*your-github-username*)
    die "${ENV_DIR}/backend.tf still has the placeholder bucket name - this environment was never provisioned." ;;
esac
info "State bucket   : ${TF_STATE_BUCKET}  (from backend.tf)"

# variables.tf currently defaults this, but a fork that drops the default would
# fail destroy on a missing required variable. Passing it explicitly is cheap.
if [ -z "${GH_ORG:-}" ]; then
  GH_ORG=$(git -C "$INFRA_DIR" remote get-url origin 2>/dev/null \
    | /usr/bin/sed -E 's#.*[:/]([^/]+)/[^/]+(\.git)?$#\1#' || true)
  [ -n "$GH_ORG" ] || GH_ORG="gulywwx"
fi
info "GitHub org     : ${GH_ORG}"

# Ask AWS rather than assuming the naming convention; fall back to it only when
# the cluster is already gone and there is nothing left to look up.
if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME=$(aws eks list-clusters --region "$AWS_REGION" \
    --query "clusters[?contains(@,'pharma-${ENV}')]|[0]" --output text 2>/dev/null || true)
  [ "$CLUSTER_NAME" = "None" ] && CLUSTER_NAME=""
  if [ -n "$CLUSTER_NAME" ]; then
    info "Cluster        : ${CLUSTER_NAME}  (found in ${AWS_REGION})"
  else
    CLUSTER_NAME="pharma-${ENV}-cluster"
    info "Cluster        : ${CLUSTER_NAME}  (not in ${AWS_REGION} - assuming convention)"
  fi
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "AWS credentials are not working."

echo
echo "  ----- About to destroy -----"
echo "  AWS account : ${ACCOUNT_ID}"
echo "  Region      : ${AWS_REGION}"
echo "  Environment : ${ENV}"
echo "  Cluster     : ${CLUSTER_NAME}"
echo "  Terraform   : ${ENV_DIR}"
echo "  ----------------------------"
echo
if $ASSUME_YES; then
  warn "--yes given - skipping the confirmation prompt."
else
  read -r -p "  Type 'destroy' to confirm: " CONFIRM </dev/tty
  [ "$CONFIRM" = "destroy" ] || die "Aborted."
fi

# ---------------------------------------------------------------------------
step "Step 1 of 12: Verify cluster connectivity"
# ---------------------------------------------------------------------------
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
  if kubectl get nodes >/dev/null 2>&1; then
    CLUSTER_UP=true
    log "Connected to ${CLUSTER_NAME}."
    kubectl get nodes --no-headers 2>/dev/null | awk '{print "     node " $1 " " $2}'
  else
    warn "Cluster exists but is unreachable - skipping Kubernetes cleanup."
  fi
else
  warn "Cluster ${CLUSTER_NAME} not found - skipping to AWS cleanup."
fi

# ---------------------------------------------------------------------------
step "Step 2 of 12: Remove ArgoCD Applications"
# ---------------------------------------------------------------------------
# selfHeal recreates anything deleted underneath ArgoCD, so the Applications
# must go before the workloads they manage.
if $CLUSTER_UP; then
  APPS=$(kubectl get applications -n argocd -o name 2>/dev/null || true)
  if [ -n "$APPS" ]; then
    echo "$APPS" | while read -r app; do info "deleting ${app##*/}"; done
    kubectl delete applications --all -n argocd --timeout=180s 2>/dev/null || true

    # resources-finalizer hangs forever if the repo or cluster is unreachable.
    STUCK=$(kubectl get applications -n argocd -o name 2>/dev/null || true)
    if [ -n "$STUCK" ]; then
      warn "Applications still present - clearing finalizers."
      echo "$STUCK" | while read -r app; do
        kubectl patch "$app" -n argocd --type=merge \
          -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done
      kubectl delete applications --all -n argocd --force --grace-period=0 >/dev/null 2>&1 || true
    fi
    log "ArgoCD Applications removed."
  else
    info "No ArgoCD Applications found."
  fi

  for ns in $APP_NAMESPACES; do
    n=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" != "0" ] && info "  ${ns}: ${n} pod(s) still terminating" || true
  done
fi

# ---------------------------------------------------------------------------
step "Step 3 of 12: Delete Ingresses and LoadBalancer Services"
# ---------------------------------------------------------------------------
# Both create an ELB that Terraform cannot see. Ingress -> ALB via the
# controller; Service type=LoadBalancer -> NLB or classic ELB via the cloud
# provider. Either one left behind blocks the VPC delete.
if $CLUSTER_UP; then
  for ns in $ALL_NAMESPACES kube-system; do
    k delete ingress --all -n "$ns" --ignore-not-found --timeout=60s
  done
  log "Ingress objects deleted."

  LBSVC=$(kubectl get svc -A -o json 2>/dev/null \
    | python3 -c 'import json,sys;[print(i["metadata"]["namespace"],i["metadata"]["name"]) for i in json.load(sys.stdin)["items"] if i.get("spec",{}).get("type")=="LoadBalancer"]' 2>/dev/null || true)
  if [ -n "$LBSVC" ]; then
    echo "$LBSVC" | while read -r ns name; do
      [ -z "${name:-}" ] && continue
      info "  deleting Service ${ns}/${name} (type=LoadBalancer)"
      kubectl delete svc "$name" -n "$ns" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
    done
    log "LoadBalancer Services deleted."
  else
    info "No LoadBalancer Services found."
  fi
fi

# ---------------------------------------------------------------------------
step "Step 4 of 12: Wait for every load balancer to be de-provisioned"
# ---------------------------------------------------------------------------
# Checks both elbv2 (ALB/NLB) and classic ELB. This is the step that decides
# whether the VPC delete succeeds.
DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  V2=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,'${ENV}')].LoadBalancerName" \
    --output text 2>/dev/null || true)
  V1=$(aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[?contains(LoadBalancerName,'${ENV}')].LoadBalancerName" \
    --output text 2>/dev/null || true)
  REMAINING="$(echo "$V2 $V1" | xargs || true)"
  [ -z "$REMAINING" ] && { log "No load balancers remain."; break; }
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    warn "Still present after 10 minutes: ${REMAINING}"
    warn "Terraform will almost certainly fail to delete the VPC."
    if $ASSUME_YES; then
      die "Aborted - load balancer still present. Continuing would strand the VPC."
    fi
    read -r -p "  Continue anyway? [y/N]: " GO </dev/tty
    [[ "${GO:-N}" =~ ^[Yy]$ ]] || die "Aborted - remove the load balancer, then re-run."
    break
  fi
  info "Waiting on: ${REMAINING}"
  sleep 15
done

# ---------------------------------------------------------------------------
step "Step 5 of 12: Release PersistentVolumes (EBS)"
# ---------------------------------------------------------------------------
# A PV with reclaimPolicy=Retain leaves its EBS volume behind, billed and
# unreferenced. Deleting the PVC first lets the provisioner clean up.
if $CLUSTER_UP; then
  PVCS=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${PVCS:-0}" != "0" ]; then
    for ns in $ALL_NAMESPACES; do
      k delete pvc --all -n "$ns" --ignore-not-found --timeout=120s
    done
    log "PersistentVolumeClaims deleted."
    RETAINED=$(kubectl get pv -o json 2>/dev/null \
      | python3 -c 'import json,sys;[print(i["metadata"]["name"]) for i in json.load(sys.stdin)["items"] if i.get("spec",{}).get("persistentVolumeReclaimPolicy")=="Retain"]' 2>/dev/null || true)
    [ -n "$RETAINED" ] && warn "Retained PVs - their EBS volumes survive: ${RETAINED}" || true
  else
    info "No PersistentVolumeClaims found."
  fi
fi

# ---------------------------------------------------------------------------
step "Step 6 of 12: Drain remaining namespaced workloads"
# ---------------------------------------------------------------------------
if $CLUSTER_UP; then
  for ns in $APP_NAMESPACES; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    k delete all --all -n "$ns" --ignore-not-found --timeout=120s
    info "  drained ${ns}"
  done
  log "Workloads drained."
fi

# ---------------------------------------------------------------------------
step "Step 7 of 12: Uninstall platform Helm releases"
# ---------------------------------------------------------------------------
# The ALB controller has to outlive the objects it manages. TargetGroupBindings
# carry a finalizer only it can clear, so uninstalling early strands them and
# the namespace hangs in Terminating.
if $CLUSTER_UP; then
  TGB=$(kubectl get targetgroupbindings -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${TGB:-0}" != "0" ]; then
    warn "${TGB} TargetGroupBinding(s) remain - clearing before controller uninstall."
    kubectl get targetgroupbindings -A -o json 2>/dev/null \
      | python3 -c 'import json,sys;[print(i["metadata"]["namespace"],i["metadata"]["name"]) for i in json.load(sys.stdin)["items"]]' 2>/dev/null \
      | while read -r ns name; do
          [ -z "${name:-}" ] && continue
          kubectl delete targetgroupbinding "$name" -n "$ns" --timeout=60s >/dev/null 2>&1 \
            || kubectl patch targetgroupbinding "$name" -n "$ns" --type=merge \
                 -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        done
  fi

  helm uninstall aws-load-balancer-controller -n kube-system      >/dev/null 2>&1 || true
  helm uninstall external-secrets             -n external-secrets >/dev/null 2>&1 || true
  helm uninstall argocd                       -n argocd           >/dev/null 2>&1 || true
  log "Platform charts uninstalled."
fi

# ---------------------------------------------------------------------------
step "Step 8 of 12: Delete namespaces"
# ---------------------------------------------------------------------------
if $CLUSTER_UP; then
  for ns in $ALL_NAMESPACES; do
    k delete namespace "$ns" --ignore-not-found --timeout=120s
  done

  # A namespace wedged in Terminating is almost always a CRD whose controller
  # is already uninstalled, so nothing is left to clear its finalizer.
  for ns in $ALL_NAMESPACES; do
    phase=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Terminating" ]; then
      warn "  ${ns} stuck Terminating - clearing namespace finalizers."
      kubectl get ns "$ns" -o json 2>/dev/null \
        | python3 -c 'import json,sys;j=json.load(sys.stdin);j["spec"]["finalizers"]=[];print(json.dumps(j))' \
        | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    fi
  done
  log "Namespaces deleted."
fi

# ---------------------------------------------------------------------------
step "Step 9 of 12: Empty ECR repositories and delete ACM certificates"
# ---------------------------------------------------------------------------
# dev sets force_delete=true so Terraform could manage ECR, but qa and prod do
# not, and one untagged image is enough to fail the destroy.
REPOS=$(aws ecr describe-repositories --region "$AWS_REGION" \
  --query 'repositories[].repositoryName' --output text 2>/dev/null || true)
if [ -z "$REPOS" ]; then
  info "No ECR repositories found."
else
  for repo in $REPOS; do
    IDS=$(aws ecr list-images --region "$AWS_REGION" --repository-name "$repo" \
      --query 'imageIds[*]' --output json 2>/dev/null || echo '[]')
    if [ "$IDS" != "[]" ]; then
      aws ecr batch-delete-image --region "$AWS_REGION" --repository-name "$repo" \
        --image-ids "$IDS" >/dev/null 2>&1 || true
      log "  cleared ${repo}"
    else
      info "  already empty: ${repo}"
    fi
  done
fi

# Hand-imported certificates are not in Terraform state. ACM refuses while one
# is attached, which is why this runs after the load balancers are gone.
CERTS=$(aws acm list-certificates --region "$AWS_REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'elb.amazonaws.com')].CertificateArn" \
  --output text 2>/dev/null || true)
if [ -z "$CERTS" ]; then
  info "No self-signed ALB certificates found."
else
  for arn in $CERTS; do
    aws acm delete-certificate --region "$AWS_REGION" --certificate-arn "$arn" 2>/dev/null \
      && log "  deleted cert ${arn##*/}" || warn "  still in use, skipped: ${arn##*/}"
  done
fi

# ---------------------------------------------------------------------------
step "Step 10 of 12: Terraform destroy"
# ---------------------------------------------------------------------------
# A cancelled run leaves a lock file that blocks every future apply.
aws s3 rm "s3://${TF_STATE_BUCKET}/envs/${ENV}/terraform.tfstate.tflock" >/dev/null 2>&1 \
  && warn "Cleared a stranded state lock." || true

cd "$ENV_DIR"
terraform init -input=false >/dev/null || die "terraform init failed."
# Only these two have no default. Destroy works from state, so the values are
# irrelevant - jwt_secret just has to clear the 32-byte minimum.
terraform destroy -auto-approve \
  -var="db_password=$(openssl rand -hex 16)" \
  -var="jwt_secret=$(openssl rand -hex 32)" \
  -var="github_org=${GH_ORG}" \
  || die "terraform destroy failed - read the error above and re-run."
log "Terraform destroy complete."

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
step "Step 11 of 12: Delete the Terraform state bucket"
# ---------------------------------------------------------------------------
# Terraform never manages its own backend, so the bucket outlives destroy.
# Discarding it also discards the record of what was provisioned - anything the
# destroy missed becomes an untracked orphan with no way to find it again.
if ! $DELETE_STATE_BUCKET; then
  info "Bucket kept. Pass --delete-state-bucket to remove it."
elif ! aws s3api head-bucket --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
  info "Bucket ${TF_STATE_BUCKET} does not exist - nothing to do."
else
  # One bucket holds every environment under envs/<env>/. Removing it while
  # another environment still has state there would strand that environment.
  OTHER=$(aws s3api list-objects-v2 --bucket "$TF_STATE_BUCKET" \
    --query "Contents[?ends_with(Key,'terraform.tfstate')].Key" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -v "^envs/${ENV}/" | grep -v '^$' || true)

  if [ -n "$OTHER" ]; then
    warn "Other environments still keep state in this bucket:"
    echo "$OTHER" | while read -r key; do warn "    ${key}"; done
    warn "Deleting it would orphan their infrastructure. Skipping."
    info "Remove those environments first, then re-run this script."
  else
    echo
    warn "This is irreversible. Without state, any resource the destroy missed"
    warn "becomes invisible to Terraform and must be found by hand."
    echo
    if $ASSUME_YES; then
      BUCKET_CONFIRM="$TF_STATE_BUCKET"
      warn "--yes given - deleting the bucket without confirmation."
    else
      read -r -p "  Type the bucket name to confirm deletion (or Enter to skip): " BUCKET_CONFIRM </dev/tty
    fi
    if [ "$BUCKET_CONFIRM" != "$TF_STATE_BUCKET" ]; then
      info "Skipped - bucket left in place."
    else
      # Versioning means delete-object only writes a delete marker, so every
      # version and every marker has to go before the bucket will drop.
      info "Deleting object versions and delete markers, 1000 at a time..."
      while true; do
        KEYS=$(aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" --max-keys 1000 \
          --query '{Objects: [Versions, DeleteMarkers][].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
          | python3 -c 'import json,sys; o=json.load(sys.stdin).get("Objects") or []; print(json.dumps({"Objects":o,"Quiet":True}) if o else "")')
        [ -z "$KEYS" ] && break
        aws s3api delete-objects --bucket "$TF_STATE_BUCKET" --delete "$KEYS" >/dev/null 2>&1 || break
      done

      aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" \
        --query '{versions: length(Versions || `[]`), markers: length(DeleteMarkers || `[]`)}' \
        --output json 2>/dev/null | /usr/bin/sed 's/^/     /' || true

      LEFT=$(aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" \
        --query 'length(Versions || `[]`) + length(DeleteMarkers || `[]`)' --output text 2>/dev/null || echo 0)
      if [ "${LEFT:-0}" != "0" ]; then
        warn "${LEFT} object version(s) remain - bucket not deleted."
      else
        aws s3api delete-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1 \
          && log "Bucket ${TF_STATE_BUCKET} deleted." \
          || warn "Bucket emptied but delete failed - check for a bucket policy or replication config."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "Step 12 of 12: Region sweep - confirm nothing remains"
# ---------------------------------------------------------------------------
# NAT gateways, Elastic IPs and unattached EBS volumes keep billing after the
# stack they belonged to is gone, and none of them appear in the console's
# default views. They are the reason this sweep exists.
REMAIN=0
check() {
  local label="$1" result="$2"
  result="$(echo "${result}" | tr '\t' ' ' | xargs || true)"
  if [ -z "$result" ] || [ "$result" = "None" ]; then
    log "  ${label}: gone"
  else
    warn "  ${label}: ${result}"
    REMAIN=$((REMAIN + 1))
  fi
}

info "Sweeping ${AWS_REGION} for anything named or tagged pharma-${ENV}..."
echo

check "EKS cluster" "$(aws eks list-clusters --region "$AWS_REGION" \
  --query "clusters[?contains(@,'pharma-${ENV}')]" --output text 2>/dev/null || true)"
check "RDS instance" "$(aws rds describe-db-instances --region "$AWS_REGION" \
  --query "DBInstances[?contains(DBInstanceIdentifier,'pharma-${ENV}')].DBInstanceIdentifier" --output text 2>/dev/null || true)"
check "RDS subnet group" "$(aws rds describe-db-subnet-groups --region "$AWS_REGION" \
  --query "DBSubnetGroups[?contains(DBSubnetGroupName,'pharma-${ENV}')].DBSubnetGroupName" --output text 2>/dev/null || true)"
check "VPC" "$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=pharma-${ENV}-vpc" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)"
check "NAT gateway (billed)" "$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
  --filter "Name=tag:Name,Values=pharma-${ENV}*" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
check "Elastic IP (billed if idle)" "$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --query "Addresses[?Tags[?Key=='Name' && contains(Value,'pharma-${ENV}')]].AllocationId" --output text 2>/dev/null || true)"
check "Load balancer (v2)" "$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName,'${ENV}')].LoadBalancerName" --output text 2>/dev/null || true)"
check "Load balancer (classic)" "$(aws elb describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancerDescriptions[?contains(LoadBalancerName,'${ENV}')].LoadBalancerName" --output text 2>/dev/null || true)"
check "Target group" "$(aws elbv2 describe-target-groups --region "$AWS_REGION" \
  --query "TargetGroups[?contains(TargetGroupName,'${ENV}')].TargetGroupName" --output text 2>/dev/null || true)"
check "EBS volume (billed)" "$(aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=status,Values=available" \
  --query "Volumes[?Tags[?contains(Value,'pharma-${ENV}')]].VolumeId" --output text 2>/dev/null || true)"
check "Security group" "$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --query "SecurityGroups[?contains(GroupName,'pharma-${ENV}') || contains(GroupName,'k8s-')].GroupName" --output text 2>/dev/null || true)"
check "ECR repository" "$(aws ecr describe-repositories --region "$AWS_REGION" \
  --query 'repositories[].repositoryName' --output text 2>/dev/null || true)"
check "Secrets Manager secret" "$(aws secretsmanager list-secrets --region "$AWS_REGION" \
  --query "SecretList[?contains(Name,'/pharma/${ENV}/')].Name" --output text 2>/dev/null || true)"
check "ACM certificate" "$(aws acm list-certificates --region "$AWS_REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'elb.amazonaws.com')].CertificateArn" --output text 2>/dev/null || true)"
check "CloudWatch log group" "$(aws logs describe-log-groups --region "$AWS_REGION" \
  --log-group-name-prefix "/aws/eks/pharma-${ENV}" --query 'logGroups[].logGroupName' --output text 2>/dev/null || true)"
check "IAM role" "$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'pharma-${ENV}')].RoleName" --output text 2>/dev/null || true)"
check "IAM policy" "$(aws iam list-policies --scope Local \
  --query "Policies[?contains(PolicyName,'pharma-${ENV}')].PolicyName" --output text 2>/dev/null || true)"
check "OIDC provider" "$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn,'${AWS_REGION}')].Arn" --output text 2>/dev/null || true)"
check "S3 state bucket" "$(aws s3api head-bucket --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1 && echo "$TF_STATE_BUCKET" || true)"

echo
if [ "$REMAIN" -eq 0 ]; then
  log "Region ${AWS_REGION} is clean - nothing left from pharma-${ENV}."
else
  warn "${REMAIN} resource type(s) still present in ${AWS_REGION} - listed above."
  warn "Anything marked (billed) costs money until removed."
fi

echo
log "Teardown finished."
echo
