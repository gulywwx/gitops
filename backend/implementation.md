# Fork setup — zen-pharma-backend CI/CD, ECR, GitOps, EKS, ArgoCD

This guide is for teams who **fork** (or copy) `zen-pharma-backend` and want GitHub Actions, AWS ECR, and GitOps-driven deploys to **their** AWS account and **their** repos. It aligns with [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md) in this repository and assumes infrastructure is provisioned using your **`zen-infra`** (or equivalent) Terraform/modules.

## Repositories involved

| Repository | Role |
|------------|------|
| `zen-pharma-backend` (fork) | Application source + GitHub Actions CI |
| `zen-gitops` (fork or new repo) | Helm values + ArgoCD Application manifests; CI writes here |
| `zen-infra` | EKS, VPC, RDS, ECR, IAM OIDC role, ArgoCD install, etc. (follow that repo’s README) |

**Placeholders to replace**

- `YOUR_ORG` — GitHub org or user owning the fork  
- `YOUR_AWS_ACCOUNT_ID` — 12-digit AWS account ID  
- `YOUR_REGION` — e.g. `us-east-1` (workflows default to `us-east-1`)

---

## Phase 0 — Decisions and forks

1. Fork **`zen-pharma-backend`** to `YOUR_ORG/zen-pharma-backend`.
2. Create a GitOps repo you control:
   - Fork upstream **`zen-gitops`** if available, **or** create `YOUR_ORG/zen-gitops` and copy the expected layout from [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md) (see Phase 5).
3. Clone **`zen-infra`** locally and read its README: note variables for cluster name, ECR, GitHub OIDC, ArgoCD, and any IRSA roles.

---

## Phase 1 — Align workflow configuration with your GitHub slugs

Upstream workflows set `GITOPS_REPO` to **`chandika-s/zen-gitops`**. After a fork, update **every** `ci-*.yml` and `promote-prod.yml` under `.github/workflows/` so that:

```yaml
env:
  GITOPS_REPO: YOUR_ORG/zen-gitops
```

Also update any hard-coded notices in shell steps that still reference `chandika-s/zen-gitops` (search the workflows directory).

**Optional:** define a repository **variable** `GITOPS_REPO` in **Settings → Secrets and variables → Actions → Variables** and reference it from workflows to avoid scattering org names (requires small workflow edits).

### IAM OIDC trust (AWS)

The trust policy example in [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md) restricts `sub` to:

`repo:chandika-s/zen-pharma-backend:*`

Change this to:

`repo:YOUR_ORG/zen-pharma-backend:*`

If you use a different IAM role name than `pharma-github-actions-role`, update **both** zen-infra (or your IaC) and the reusable workflows [`_java-build.yml`](./.github/workflows/_java-build.yml) / [`_node-build.yml`](./.github/workflows/_node-build.yml) (`role-to-assume`).

---

## OIDC and IAM role — AWS CLI (`pharma-github-actions-role`)

Use this sequence when provisioning the GitHub Actions → AWS trust by hand (same shape as [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md)). **Role name:** `pharma-github-actions-role`.

**Forks:** Replace `020930354342` with your account ID everywhere below, and change `token.actions.githubusercontent.com:sub` to `repo:YOUR_ORG/zen-pharma-backend:*` (and update the `Federated` ARN so the account ID in `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/...` matches).

### Step 1 — Create the GitHub OIDC identity provider (once per account)

This registers the GitHub Actions issuer so IAM can trust its tokens. If you see `EntityAlreadyExists`, the provider is already present—skip to Step 2.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

To confirm:

```bash
aws iam list-open-id-connect-providers
```

### Step 2 — Trust policy (exact)

Save as `trust-policy.json` (values below match production for account `020930354342` and repo `chandika-s/zen-pharma-backend`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::020930354342:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:chandika-s/zen-pharma-backend:*"
        }
      }
    }
  ]
}
```

### Step 3 — Create the IAM role

```bash
aws iam create-role \
  --role-name pharma-github-actions-role \
  --assume-role-policy-document file://trust-policy.json \
  --description "GitHub Actions OIDC role for zen-pharma-backend CI/CD (ECR push)"
```

### Step 4 — Permission policy (exact — ECR only)

Save as `pharma-ecr-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:ListImages",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:us-east-1:020930354342:repository/*"
    }
  ]
}
```

### Step 5 — Attach the inline policy to the role

```bash
aws iam put-role-policy \
  --role-name pharma-github-actions-role \
  --policy-name pharma-ecr-access \
  --policy-document file://pharma-ecr-policy.json
```

### Step 6 — Verify

```bash
aws iam get-role --role-name pharma-github-actions-role --query 'Role.Arn' --output text

aws iam get-role-policy \
  --role-name pharma-github-actions-role \
  --policy-name pharma-ecr-access
```

GitHub Actions assumes:

`arn:aws:iam::<AWS_ACCOUNT_ID>:role/pharma-github-actions-role`

Set repository secret **`AWS_ACCOUNT_ID`** to `020930354342` (or your account ID) so [`_java-build.yml`](./.github/workflows/_java-build.yml) / [`_node-build.yml`](./.github/workflows/_node-build.yml) can construct that ARN.

---

## Phase 2 — AWS via zen-infra (EKS, networking, ECR, IAM)

Complete these using **zen-infra** where possible; use the AWS CLI only for steps not covered by modules.

1. **VPC / EKS** — Apply zen-infra modules so you have a working cluster and node groups (or Fargate), per zen-infra docs.
2. **ECR repositories** — One repository per microservice (names must match workflows):

   - `api-gateway`
   - `auth-service`
   - `drug-catalog-service`
   - `inventory-service`
   - `manufacturing-service`
   - `notification-service`
   - `supplier-service`

   Enable **scan on push** if your policy requires it (recommended in `CI-ARCHITECTURE.md`).

3. **GitHub OIDC + CI IAM role** — Use the [OIDC and IAM role — AWS CLI](#oidc-and-iam-role--aws-cli-pharma-github-actions-role) section above, or equivalent resources in zen-infra (same trust and ECR-only permissions).

4. **Cosign / admission** — If production enforces signed images, zen-infra should install **Kyverno** (or equivalent) policies that verify Cosign signatures, consistent with how [`_java-build.yml`](./.github/workflows/_java-build.yml) signs images after push.

---

## Phase 3 — ArgoCD on EKS

1. **Install ArgoCD** — Via zen-infra Helm/module or the official Helm chart; secure the server (ingress, SSO, TLS) per your organization.
2. **Register the GitOps repo** — Add **read** credentials (SSH deploy key or HTTPS token) so ArgoCD can pull `YOUR_ORG/zen-gitops`. CI uses a separate **write** token (`GITOPS_TOKEN`).
3. **Bootstrap Applications** — Apply manifests under `argocd/apps/` in your gitops repo. Typical pattern for this project:

   - **DEV:** one ArgoCD Application per service, **auto-sync**
   - **QA:** one app watching `envs/qa/`, **auto-sync**
   - **PROD:** one app watching `envs/prod/`, **manual sync**

4. **Image pull** — Nodes or workloads need permission to pull from ECR; zen-infra usually wires IRSA or node instance profiles.

---

## Phase 4 — GitHub configuration (forked `zen-pharma-backend`)

### 4.1 Repository secrets

**Settings → Secrets and variables → Actions → Secrets**

| Secret | Required | Purpose |
|--------|----------|---------|
| `AWS_ACCOUNT_ID` | Yes | Used in `role-to-assume` ARN and ECR URL construction |
| `GITOPS_TOKEN` | Yes | PAT or GitHub App token with **`contents: write`** (and ability to open PRs) on **`YOUR_ORG/zen-gitops`** |

The workflows check out zen-gitops, commit, push, and use `gh pr create`. Ensure the token can push branches and open pull requests in the gitops repository.

### 4.2 Environments

**Settings → Environments**

| Environment | Protection |
|-------------|------------|
| `dev` | None (deploy job runs without approval) |
| `prod` | **Required reviewers** for [`promote-prod.yml`](./.github/workflows/promote-prod.yml) |

### 4.3 Actions and forks

Ensure **Actions** are enabled on the fork. For **forked repositories**, GitHub may restrict workflows that use secrets on `pull_request` from external contributors; align with your org’s security policy.

### 4.4 Branch strategy

CI is wired for:

- Feature branches: `feat-*`, `fix-*`, `chore-*` → lightweight `ci-pr-*.yml`
- Full build + ECR + gitops: **`develop`** and **`release/**`**

Ensure your integration branch is named **`develop`** or update `branches:` in each workflow.

---

## Phase 5 — GitOps repo layout (`YOUR_ORG/zen-gitops`)

Mirror the structure described in [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md):

```text
zen-gitops/
├── argocd/apps/
│   ├── dev/          # one Application YAML per service (auto-sync)
│   ├── qa/           # e.g. pharma-qa app (auto-sync)
│   └── prod/         # e.g. pharma-prod app (manual sync)
└── envs/
    ├── dev/
    ├── qa/
    └── prod/
```

**Image values** must point at **your** ECR:

```yaml
image:
  repository: YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/<service>
  tag: <patched-by-ci>
  pullPolicy: IfNotPresent
```

**Drug catalog:** upstream uses `GITOPS_SERVICE_NAME: catalog-service` in [`ci-drug-catalog.yml`](./.github/workflows/ci-drug-catalog.yml) while ECR remains `drug-catalog-service`. Keep dev values filenames and Helm release names consistent with what that workflow patches.

---

## Phase 6 — Verification checklist

1. **AWS:** OIDC provider exists; IAM role trust matches `YOUR_ORG/zen-pharma-backend`; ECR repos exist; role can assume and push (optional smoke test).
2. **GitHub:** Secrets and environments configured; `GITOPS_TOKEN` can clone, push, and open PRs on the gitops repo.
3. **Workflows:** All `GITOPS_REPO` values point to `YOUR_ORG/zen-gitops`.
4. **ArgoCD:** Applications sync from your gitops repo; DEV reaches Healthy after CI updates `envs/dev/values-<service>.yaml`.
5. **End-to-end:** Push a change to **`develop`** under one service path (e.g. `api-gateway/`) → build → ECR tag `sha-xxxxxxx` → dev values updated → ArgoCD rolls out.

---

## Phase 7 — Operations reminders

- **QA / PROD promotion** requires corresponding **`envs/qa/`** and **`envs/prod/`** values files; otherwise CI logs a warning and skips opening the promotion PR (see FAQ in [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md)).
- **PROD** uses manual ArgoCD sync after the PROD PR merges (`syncPolicy: Manual` for the prod app).
- **Semgrep, CodeQL, Trivy** on private forks may require GitHub Advanced Security or appropriate permissions.

---

## References in this repository

| Resource | Description |
|----------|-------------|
| [`CI-ARCHITECTURE.md`](./CI-ARCHITECTURE.md) | Full CI/CD architecture, OIDC steps, ECR policy JSON, gitops layout |
| [`.github/workflows/_java-build.yml`](./.github/workflows/_java-build.yml) | Java build, ECR, Cosign, OIDC role |
| [`.github/workflows/_node-build.yml`](./.github/workflows/_node-build.yml) | Node build path |
| [`.github/workflows/ci-*.yml`](./.github/workflows/) | Per-service full pipeline + gitops jobs |
| [`.github/workflows/promote-prod.yml`](./.github/workflows/promote-prod.yml) | Manual PROD promotion |

Details not covered here (cluster sizing, RDS, ArgoCD SSO, exact Terraform variables) should be taken from **`zen-infra`** and reconciled with role names, region, and cluster identifiers used in these workflows.

---

## Optional — NIST NVD API key (`NVD_API_KEY`)

Java CI runs **OWASP Dependency Check**, which downloads vulnerability metadata from the **NIST National Vulnerability Database (NVD)**. Without an API key, NVD applies strict rate limits and the step can be slow; with a key, requests are faster and more reliable.

This is **optional**: workflows still run OWASP if the secret is missing; adding the key only improves speed and rate limits.

**Steps (once per repository)**

1. Request a key from NIST: open [NVD — Request an API Key](https://nvd.nist.gov/developers/request-an-api-key) and submit the form. Use a mailbox you can access; NIST emails a verification link.
2. After verifying, copy the API key from NIST’s confirmation.
3. In GitHub: **Settings → Secrets and variables → Actions → New repository secret**.
4. **Name:** `NVD_API_KEY` (exact name — workflows pass it to the Maven plugin via the environment).
5. **Value:** paste the key and save.
6. Ensure workflows that call `_java-pr-check.yml` / `_java-build.yml` use **`secrets: inherit`** (upstream already does) so the secret is available.

More detail: [NVD API key (OWASP Dependency Check)](./CI-ARCHITECTURE.md#nvd-api-key-owasp-dependency-check) in `CI-ARCHITECTURE.md`.
