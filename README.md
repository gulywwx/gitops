# gitops — Implementation Guide

Set up the pharmacy infrastructure in your own AWS account from scratch. The sections below run in dependency order, so work through them top to bottom.

| Section | What it does |
|---|---|
| [1. Prerequisites](#1-prerequisites) | Install the required CLI tools |
| [2. Clone the repository](#2-clone-the-repository) | Get the code locally |
| [3. Create the Terraform IAM user](#3-create-the-terraform-iam-user) | Bootstrap credentials |
| [4. Create the S3 state backend](#4-create-the-s3-state-backend) | Remote state storage |
| [5. Configure GitHub secrets and variables](#5-configure-github-secrets-and-variables) | Wire up CI |
| [6. Provision the infrastructure](#6-provision-the-infrastructure) | VPC, EKS, RDS, ECR |
| [7. Bootstrap the cluster](#7-bootstrap-the-cluster) | ALB controller, ArgoCD, ESO |
| [8. Tear everything down](#8-tear-everything-down) | Destroy and clean up |

Steps 3 and 4 must happen before step 5, because the values you paste into GitHub come from them.

---

## 1. Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| Terraform | 1.10 | `use_lockfile` S3 native locking needs 1.10 or newer |
| AWS CLI | 2.x | Provisioning and state bucket management |
| kubectl | 1.29 | Cluster access |
| Helm | 3.x | Installs the bootstrap components |
| Python | 3.9 | Runs the `infra/scripts/` installers |

```bash
terraform version && aws --version && kubectl version --client && helm version --short && python3 --version
```

CI pins Terraform to 1.15.6. Any 1.10 or newer release works locally, but staying close to the pinned version avoids state-format surprises.

---

## 2. Clone the repository

```bash
git clone https://github.com/gulywwx/gitops.git
cd gitops
```

Working from your own fork? Replace `gulywwx` with your GitHub username here and everywhere else it appears below.

---

## 3. Create the Terraform IAM user

OIDC is set up later by Terraform itself, so the first run needs a plain IAM user with an access key.

In **AWS Console → IAM → Users → Create user**:

- Username: `terraform-admin`
- Access type: Programmatic access
- Permissions: attach `AdministratorAccess`

Save the **Access Key ID** and **Secret Access Key**. You will paste both into GitHub in [step 5](#5-configure-github-secrets-and-variables).

> For production, scope the policy down to the services Terraform actually touches: EC2, EKS, RDS, ECR, IAM, Secrets Manager, S3, VPC.

Configure the CLI:

```bash
aws configure
# AWS Access Key ID: <your-access-key-id>
# AWS Secret Access Key: <your-secret-access-key>
# Default region name: us-east-1
# Default output format: json
```

Confirm it works:

```bash
aws sts get-caller-identity
# Returns your account ID, user ARN, and user ID
```

---

## 4. Create the S3 state backend

Terraform needs this bucket to exist before its first `init`. Bucket names are globally unique, so append your GitHub username.

```bash
BUCKET=pharmacy-terraform-state-gulywwx

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1

# Versioning lets you roll back a corrupted or accidentally deleted state file
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" }
    }]
  }'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Verify (empty output, no error):

```bash
aws s3 ls s3://pharmacy-terraform-state-gulywwx
```

Now point the backend at it. Edit `infra/envs/dev/backend.tf` and set `bucket` to your name:

```hcl
terraform {
  backend "s3" {
    bucket       = "pharmacy-terraform-state-gulywwx"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

`infra/envs/qa/backend.tf` and `infra/envs/prod/backend.tf` still contain the `YOUR-GITHUB-USERNAME` placeholder. Only `dev` is wired up; update the others before you use those environments.

> Keep versioning on. It is the only thing standing between an accidental `aws s3 rm --recursive` and a lost state file.

---

## 5. Configure GitHub secrets and variables

Go to **Settings → Secrets and variables → Actions** in your fork.

Under **Secrets**, add seven:

| Secret | Value | Purpose |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Access key from [step 3](#3-create-the-terraform-iam-user) | Authenticates Terraform in CI |
| `AWS_SECRET_ACCESS_KEY` | Secret key from [step 3](#3-create-the-terraform-iam-user) | Authenticates Terraform in CI |
| `AWS_ACCOUNT_ID` | Your 12-digit account number, e.g. `123456789012` | Builds the IAM role ARN and ECR registry URL in the app pipeline |
| `DEV_DB_PASSWORD` | RDS master password, 8 characters or more | Passed to `terraform apply` as `db_password` |
| `DEV_JWT_SECRET` | Random string, e.g. `openssl rand -hex 32` | Passed to `terraform apply` as `jwt_secret` |
| `GITOPS_TOKEN` | GitHub PAT with `repo` scope | Write access to the gitops repo for updating image tags and opening PRs |
| `SONAR_TOKEN` | SonarCloud token | Authenticates SonarCloud SAST and code-quality scans |

Look up your account ID with:

```bash
aws sts get-caller-identity --query Account --output text
```

Create `GITOPS_TOKEN` under **Settings → Developer settings → Personal access tokens**. A classic token needs the `repo` scope; a fine-grained one needs **Contents: read and write** plus **Pull requests: read and write** on this repository. The default `GITHUB_TOKEN` cannot be used here, because it has no access to other repositories.

Get `SONAR_TOKEN` from **SonarCloud → My Account → Security → Generate Token**.

Under **Variables**, add five:

| Variable | Value | Purpose |
|---|---|---|
| `GH_ORG` | `gulywwx` | Passed to Terraform as `github_org` for the OIDC trust policy |
| `TF_STATE_BUCKET` | `pharmacy-terraform-state-gulywwx` | Lets CI clear a stranded state lock after a cancelled run |
| `GITOPS_REPO` | `gulywwx/gitops` (your org/repo) | Tells the app pipeline which repo to update with new image tags |
| `SONAR_ORG` | Your SonarCloud organization key | Identifies your SonarCloud organization |
| `SONAR_PROJECT_KEY` | Project key in SonarCloud | Shared by the frontend and all backend service pipelines |

Check them from the CLI:

```bash
gh secret list
gh variable list
```

`TF_STATE_BUCKET` is what the workflow uses to clear a stranded state lock after a cancelled run. Leave it unset and that cleanup silently does nothing.

The workflows draw on different subsets. `infra.yml` reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DEV_DB_PASSWORD`, `DEV_JWT_SECRET`, `GH_ORG`, and `TF_STATE_BUCKET`. `ci-pharma-ui.yml` and the per-service `ci-*.yml` workflows read `AWS_ACCOUNT_ID`, `GITOPS_TOKEN`, and `GITOPS_REPO`.

`SONAR_TOKEN`, `SONAR_ORG`, and `SONAR_PROJECT_KEY` are consumed by the SonarCloud step in the reusable build workflows. Leave any of the three unset and that step is skipped with a warning rather than failing the build.

---

## 6. Provision the infrastructure

### Via the pipeline (recommended)

Open a PR against `main`. The **Terraform Plan** job runs automatically and posts the plan. Merge it, and the **Terraform Apply** job pauses on the `dev` environment gate until you approve it in the Actions tab.

You can also trigger it by hand: **Actions → Terraform Infrastructure → Run workflow**, with action `plan` or `apply`.

### Locally

```bash
cd infra/envs/dev
terraform init
terraform plan  -var="db_password=Password|26" -var="jwt_secret=Password|26" -var="github_org=gulywwx"
terraform apply -var="db_password=Password|26" -var="jwt_secret=Password|26" -var="github_org=gulywwx"
```

Use the same values you stored in `DEV_DB_PASSWORD` and `DEV_JWT_SECRET`. If they differ, the next CI run will plan a change to the RDS password and the Secrets Manager entries.

Expect 15 to 25 minutes: roughly 10 for the EKS control plane, 5 for the node group, 5 for RDS.

Then connect:

```bash
aws eks update-kubeconfig --name pharma-dev-cluster --region us-east-1
kubectl get nodes
```

---

## 7. Bootstrap the cluster

Terraform builds the AWS resources. These scripts install what runs inside the cluster: the AWS Load Balancer Controller, ArgoCD, and the External Secrets Operator.

Collect the two values the first script asks for:

```bash
# VPC ID
aws eks describe-cluster --name pharma-dev-cluster --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text

# ALB controller role ARN
aws iam list-roles \
  --query "Roles[?contains(RoleName, 'alb-controller')].Arn" --output text
```

Run them in order:

```bash
cd infra/scripts
python3 01_install_prerequisites.py
python3 02_bootstrap_argocd.py
python3 03_setup_external_secrets.py
python3 05_deploy_services.py

```

`01_install_prerequisites.py` prints the ArgoCD admin password once, at the end. Save it. To reach the UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  (user: admin)
```

The remaining scripts (`03` through `06`) cover External Secrets, the app pipeline, service deployment, and verification.

---

## 8. Tear everything down

> Destroys the EKS cluster, the RDS instance, and all data in it. There is no undo.

### Via the pipeline (recommended)

**Actions → Terraform Infrastructure → Run workflow**:

- Terraform action: `destroy`
- Type "destroy" to confirm: `destroy`

The job stops at the `dev` environment gate for approval.

### Locally

```bash

aws ecr batch-delete-image --region us-east-1 \
  --repository-name pharma-ui \
  --image-ids "$(aws ecr list-images --region us-east-1 \
      --repository-name pharma-ui --query 'imageIds[*]' --output json)"

cd infra/envs/dev
terraform init
terraform destroy \
  -var="db_password=Password|26" \
  -var="jwt_secret=Password|26" \
  -var="github_org=gulywwx"
```

Type `yes` when prompted.

### Delete the state bucket

Terraform does not manage its own backend, so the bucket outlives `destroy`. Versioning means `aws s3 rm --recursive` only writes delete markers; every version has to go before S3 will drop the bucket.

```bash
BUCKET=pharmacy-terraform-state-gulywwx

# Deletes object versions and delete markers together, 1000 at a time
while true; do
  KEYS=$(aws s3api list-object-versions --bucket "$BUCKET" --max-keys 1000 \
    --query '{Objects: [Versions, DeleteMarkers][].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
    | python3 -c 'import json,sys; o=json.load(sys.stdin).get("Objects") or []; print(json.dumps({"Objects":o,"Quiet":True}) if o else "")')
  [ -z "$KEYS" ] && break
  aws s3api delete-objects --bucket "$BUCKET" --delete "$KEYS"
done

aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{versions: length(Versions || `[]`), markers: length(DeleteMarkers || `[]`)}'

aws s3api delete-bucket --bucket "$BUCKET" --region us-east-1
```

---

## Troubleshooting

**`Error acquiring the state lock`, StatusCode 412**

Something else holds the lock. Check the Actions tab for a run still in flight before touching anything. If nothing is running, the lock was stranded by a cancelled job:

```bash
aws s3 rm s3://pharmacy-terraform-state-gulywwx/envs/dev/terraform.tfstate.tflock
```

**`terraform fmt -check` fails in CI**

Run `terraform fmt -recursive infra/` and commit. CI runs from `infra/envs/dev`, so its output shows bare filenames with no directory prefix.

**Webhook `x509: certificate signed by unknown authority` during bootstrap**

The ALB controller's webhook cert and the pods serving it are briefly out of sync. `01_install_prerequisites.py` restarts the deployment and waits for the webhook to answer. If it persists:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Reference

Course material:

- [DevOps Workshop (Udemy)](https://versentau.udemy.com/course/devops-workshop/learn/lecture/56993519#overview)
- [Valaxy Technologies (YouTube)](https://www.youtube.com/@ValaxyTechnologies/videos)

Upstream repositories:

- [zenpharma](https://github.com/zenpharma) — [documents](https://github.com/zenpharma/documents), [infra](https://github.com/zenpharma/infra), [gitops](https://github.com/zenpharma/gitops), [frontend](https://github.com/zenpharma/frontend), [backend](https://github.com/zenpharma/backend)
- [ravdy](https://github.com/ravdy) — [zen-infra](https://github.com/ravdy/zen-infra), [zen-gitops](https://github.com/ravdy/zen-gitops), [zen-pharma-frontend](https://github.com/ravdy/zen-pharma-frontend), [zen-pharma-backend](https://github.com/ravdy/zen-pharma-backend)

---

## Roadmap

- [x] Merge the separate repositories into one
- [ ] Install ArgoCD and the other bootstrap components through Terraform instead of the Python scripts

---

*Terraform 1.10+ · GitHub Actions · AWS EKS, RDS, ECR, VPC, IAM, Secrets Manager*
