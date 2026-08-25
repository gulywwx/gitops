# QC Service — Deployment Implementation Guide

> **Context:** The platform already runs 8 Spring Boot microservices on EKS with ArgoCD GitOps.
> This guide adds `qc-service` as the 9th service end-to-end: ECR → CI/CD → Helm → ArgoCD → API Gateway.

---

## Repositories Involved

| Repo | Purpose |
|------|---------|
| `zen-pharma-backend` | Application source code + GitHub Actions workflows |
| `zen-infra` | Terraform infrastructure (ECR, EKS, RDS, IAM) |
| `zen-gitops` | Helm values + ArgoCD Application manifests |

---

## Overview of Changes

```
zen-pharma-backend/
  qc-service/Dockerfile                              ← NEW
  api-gateway/src/main/resources/application.yml    ← UPDATED (add routes)
  .github/workflows/ci-qc-service.yml               ← NEW
  .github/workflows/ci-pr-qc-service.yml            ← NEW

zen-infra/
  envs/dev/main.tf                                  ← UPDATED (add ECR repo)
  envs/qa/main.tf                                   ← UPDATED (add ECR repo)
  envs/prod/main.tf                                 ← UPDATED (add ECR repo)

zen-gitops/
  envs/dev/values-qc-service.yaml                  ← NEW
  envs/qa/values-qc-service.yaml                   ← NEW
  envs/prod/values-qc-service.yaml                 ← NEW
  envs/dev/values-api-gateway.yaml                 ← UPDATED (add QC_SERVICE_URL)
  envs/qa/values-api-gateway.yaml                  ← UPDATED (add QC_SERVICE_URL)
  envs/prod/values-api-gateway.yaml                ← UPDATED (add QC_SERVICE_URL)
  argocd/apps/dev/qc-service-app.yaml              ← NEW
  argocd/apps/qa/qc-service-app.yaml               ← NEW
  argocd/apps/prod/qc-service-app.yaml             ← NEW
```

---

## Step 1 — Provision ECR Repository (Terraform)

The ECR repository must exist before any Docker image can be pushed.

### 1.1 Update Terraform in all three environments

In each of the files below, add `"qc-service"` to the `repositories` list inside `module "ecr"`:

**Files to update:**
- `zen-infra/envs/dev/main.tf`
- `zen-infra/envs/qa/main.tf`
- `zen-infra/envs/prod/main.tf`

**Change to make (same in all three):**

```hcl
module "ecr" {
  source = "../../modules/ecr"

  project = "pharma"
  env     = "dev"   # changes to qa / prod per file
  repositories = [
    "api-gateway",
    "auth-service",
    "drug-catalog-service",
    "inventory-service",
    "manufacturing-service",
    "notification-service",
    "pharma-ui",
    "supplier-service",
    "qc-service"        # ← add this line
  ]
}
```

### 1.2 Apply Terraform

```bash
# DEV
cd zen-infra/envs/dev
terraform init
terraform plan
terraform apply

# QA
cd ../qa
terraform init
terraform plan
terraform apply

# PROD
cd ../prod
terraform init
terraform plan
terraform apply
```

**Expected result:** Three new ECR repositories created:
- `873135413040.dkr.ecr.us-east-1.amazonaws.com/qc-service` (dev)
- `873135413040.dkr.ecr.us-east-1.amazonaws.com/qc-service` (qa)
- `873135413040.dkr.ecr.us-east-1.amazonaws.com/qc-service` (prod)

---

## Step 2 — Add Dockerfile to qc-service

**File:** `zen-pharma-backend/qc-service/Dockerfile`

```dockerfile
FROM eclipse-temurin:17-jre
WORKDIR /app
RUN groupadd -r pharma && useradd -r -g pharma pharma
COPY target/*.jar app.jar
USER pharma
EXPOSE 8086
ENTRYPOINT ["java", "-jar", "-Djava.security.egd=file:/dev/./urandom", "app.jar"]
```

**Key points:**
- Uses `eclipse-temurin:17-jre` — same base image as all other Java services.
- Runs as non-root user `pharma` (security requirement).
- Port `8086` is the qc-service port defined in `application.yml`.
- JAR is pre-built by Maven in CI before Docker build runs.

---

## Step 3 — Add GitHub Actions CI/CD Workflows

Two workflow files are needed — one for the main pipeline (build + deploy) and one for PR checks.

### 3.1 Main CI/CD pipeline

**File:** `zen-pharma-backend/.github/workflows/ci-qc-service.yml`

```yaml
name: CI/CD — qc-service

on:
  push:
    branches: [develop, 'release/**']
    paths:
      - 'qc-service/**'
      - '.github/workflows/ci-qc-service.yml'

permissions:
  id-token: write
  contents: read
  security-events: write
  actions: read

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: qc-service
  GITOPS_REPO: ${{ vars.GITOPS_REPO }}

jobs:

  build:
    name: Build & Security Gates
    uses: ./.github/workflows/_java-build.yml
    with:
      service-name: qc-service
      service-dir: qc-service
      ecr-repository: qc-service
      aws-region: us-east-1
      needs-database: false
    secrets: inherit

  deploy-dev:
    name: Deploy — DEV
    needs: build
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4

      - name: Checkout GitOps repo
        uses: actions/checkout@v4
        with:
          repository: ${{ env.GITOPS_REPO }}
          token: ${{ secrets.GITOPS_TOKEN }}
          path: _gitops

      - name: Update image tag — DEV
        env:
          IMAGE_TAG: ${{ needs.build.outputs.image-tag }}
        run: |
          yq e ".image.tag = \"${IMAGE_TAG}\"" -i \
            "_gitops/envs/dev/values-qc-service.yaml"
          cd _gitops
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git diff --staged --quiet && echo "Already up to date" && exit 0
          git commit -m "ci(dev): update qc-service → ${IMAGE_TAG}"
          git push

  open-qa-pr:
    name: Open PR — QA Promotion
    needs: [build, deploy-dev]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Checkout GitOps repo
        uses: actions/checkout@v4
        with:
          repository: ${{ env.GITOPS_REPO }}
          token: ${{ secrets.GITOPS_TOKEN }}
          path: _gitops

      - name: Create branch, commit, open PR
        env:
          GH_TOKEN: ${{ secrets.GITOPS_TOKEN }}
          IMAGE_TAG: ${{ needs.build.outputs.image-tag }}
          REF_NAME: ${{ github.ref_name }}
          ACTOR: ${{ github.actor }}
          SERVER_URL: ${{ github.server_url }}
          REPOSITORY: ${{ github.repository }}
          RUN_ID: ${{ github.run_id }}
          GITOPS_REPO_NAME: ${{ env.GITOPS_REPO }}
        run: |
          VALUES="_gitops/envs/qa/values-qc-service.yaml"
          BRANCH="promote/qa/qc-service/${IMAGE_TAG}"

          if [[ ! -f "$VALUES" ]]; then
            echo "::warning::$VALUES not found — QA PR skipped."
            exit 0
          fi

          cd _gitops
          git checkout -b "$BRANCH"
          yq e ".image.tag = \"${IMAGE_TAG}\"" -i "envs/qa/values-qc-service.yaml"
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          if git diff --staged --quiet; then
            echo "QA already has this image — no PR needed"
            exit 0
          fi
          git commit -m "promote(qa): qc-service → ${IMAGE_TAG}"
          git push --force-with-lease origin "$BRANCH"

          printf '%s\n' \
            "## QA Promotion" \
            "" \
            "Service : qc-service" \
            "Image   : ${IMAGE_TAG}" \
            "Branch  : ${REF_NAME}" \
            "Actor   : ${ACTOR}" \
            "Build   : ${SERVER_URL}/${REPOSITORY}/actions/runs/${RUN_ID}" \
            "" \
            "## Checklist" \
            "- [ ] DEV smoke test passed (see build link above)" \
            "- [ ] No unexpected config changes in this diff" \
            "- [ ] QA team sign-off" \
            "" \
            "Merging this PR updates envs/qa/values-qc-service.yaml." \
            "ArgoCD (pharma-qa) auto-syncs on merge." > /tmp/pr-body.md

          PR_URL=$(gh pr view --repo "$GITOPS_REPO_NAME" --head "$BRANCH" --json url -q .url 2>/dev/null || true)
          if [[ -n "$PR_URL" ]]; then
            echo "::notice title=QA PR already open::${PR_URL}"
          else
            gh pr create \
              --repo "$GITOPS_REPO_NAME" \
              --title "promote(qa): qc-service → ${IMAGE_TAG}" \
              --body-file /tmp/pr-body.md \
              --base main \
              --head "$BRANCH"
          fi

  dast:
    name: DAST — ZAP Baseline (DEV)
    if: false
    needs: deploy-dev
    runs-on: ubuntu-latest
    steps:
      - name: Wait for DEV service to be healthy
        run: |
          URL="${{ vars.DEV_QC_SERVICE_URL }}/actuator/health"
          for i in $(seq 1 20); do
            curl -sf "$URL" && echo "Healthy" && exit 0
            echo "Attempt $i/20 — retrying in 15s..."
            sleep 15
          done
          echo "::error::DEV endpoint not healthy after 5 minutes"
          exit 1

      - name: OWASP ZAP — Baseline scan
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: ${{ vars.DEV_QC_SERVICE_URL }}
          fail_action: warn
          artifact_name: zap-report-qc-service
```

**Key points:**
- Triggers only when files under `qc-service/` change on `develop` or `release/**` branches.
- Calls the shared `_java-build.yml` reusable workflow — do not duplicate build logic.
- `needs-database: false` — qc-service uses H2 in-memory, no PostgreSQL container needed.
- `deploy-dev` job uses `yq` to update the image tag in the gitops repo values file and pushes directly.
- `open-qa-pr` creates a branch in the gitops repo and opens a PR — QA promotion is always a manual merge decision.
- DAST scan is disabled (`if: false`) until `DEV_QC_SERVICE_URL` is set in GitHub repository variables.

### 3.2 PR check workflow

**File:** `zen-pharma-backend/.github/workflows/ci-pr-qc-service.yml`

```yaml
name: PR Check — qc-service

on:
  push:
    branches: ['feat-*', 'fix-*', 'chore-*']
    paths:
      - 'qc-service/**'
      - '.github/workflows/ci-pr-qc-service.yml'
  pull_request:
    branches: [develop]
    paths:
      - 'qc-service/**'

permissions:
  contents: read
  pull-requests: read
  security-events: write
  actions: read

jobs:
  pr-check:
    uses: ./.github/workflows/_java-pr-check.yml
    with:
      service-name: qc-service
      service-dir: qc-service
      needs-database: false
    secrets: inherit
```

**Key points:**
- Runs on feature/fix/chore branches and on PRs targeting `develop`.
- Does NOT push to ECR or deploy anywhere — read-only quality gate.
- Calls shared `_java-pr-check.yml` reusable workflow.

### 3.3 Required GitHub secrets / variables

These already exist for other services. Confirm they are set before pushing:

| Type | Name | Description |
|------|------|-------------|
| Secret | `AWS_ACCOUNT_ID` | `873135413040` |
| Secret | `AWS_ROLE_ARN` | IAM role for GitHub OIDC |
| Secret | `GITOPS_TOKEN` | GitHub PAT with `repo` scope on zen-gitops |
| Variable | `GITOPS_REPO` | `ravdy/zen-gitops` |

### 3.4 Commit and push the backend changes

```bash
cd zen-pharma-backend

git add qc-service/Dockerfile \
        api-gateway/src/main/resources/application.yml \
        .github/workflows/ci-qc-service.yml \
        .github/workflows/ci-pr-qc-service.yml

git commit -m "feat(qc-service): add Dockerfile, CI workflows, and api-gateway route"
git push origin develop
```

Pushing to `develop` triggers `ci-qc-service.yml` automatically. The pipeline will:
1. Run tests and security scans
2. Build and push the Docker image to ECR as `sha-<7chars>`
3. Update `envs/dev/values-qc-service.yaml` in zen-gitops with the new tag
4. Open a PR to promote the same tag to QA

---

## Step 4 — Add Helm Values Files (zen-gitops)

These files tell the shared Helm chart how to deploy qc-service in each environment.

### 4.1 DEV values

**File:** `zen-gitops/envs/dev/values-qc-service.yaml`

```yaml
replicaCount: 1
fullnameOverride: qc-service
image:
  repository: 873135413040.dkr.ecr.us-east-1.amazonaws.com/qc-service
  tag: sha-0000000   # CI overwrites this on first successful build
  pullPolicy: Always
service:
  type: ClusterIP
  port: 8086
  targetPort: 8086
ingress:
  enabled: false
  className: nginx
  host: dev.pharma.internal
  path: /qc
  pathType: Prefix
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
livenessProbe:
  path: /actuator/health
  port: 8086
  initialDelaySeconds: 60
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1
readinessProbe:
  path: /actuator/health/readiness
  port: 8086
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1
configmap:
  SPRING_PROFILES_ACTIVE: dev
  LOG_LEVEL: DEBUG
  SERVER_PORT: "8086"
  MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE: "health,info,metrics,prometheus"
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}
serviceAccount:
  create: true
  annotations: {}
  name: qc-service
```

### 4.2 QA values

**File:** `zen-gitops/envs/qa/values-qc-service.yaml`

Same as DEV with these differences:

```yaml
configmap:
  SPRING_PROFILES_ACTIVE: qa   # ← changed
  LOG_LEVEL: DEBUG
```

### 4.3 PROD values

**File:** `zen-gitops/envs/prod/values-qc-service.yaml`

Same as DEV with these differences:

```yaml
replicaCount: 2                # ← increased for HA

autoscaling:
  minReplicas: 2               # ← increased
  maxReplicas: 5               # ← increased

configmap:
  SPRING_PROFILES_ACTIVE: prod # ← changed
  LOG_LEVEL: INFO              # ← INFO not DEBUG in prod
```

> **Why no `envFrom` / secrets?**
> qc-service uses H2 in-memory database — it does not connect to RDS and does not require `db-credentials` or `jwt-secret`. If you migrate to PostgreSQL later, add an `envFrom` block matching the other services.

---

## Step 5 — Update API Gateway Route

The api-gateway is the single entry point for all services. It must know about qc-service.

### 5.1 Add the routes

**File:** `zen-pharma-backend/api-gateway/src/main/resources/application.yml`

Add **two** route blocks after the `manufacturing-service` route, before `globalcors`:

```yaml
        - id: qc-service-root
          uri: "${QC_SERVICE_URL:http://qc-service:8086}"
          predicates:
            - Path=/api/qc
          filters:
            - AuthFilter
            - RewritePath=/api/qc, /api/qc/inspections

        - id: qc-service
          uri: "${QC_SERVICE_URL:http://qc-service:8086}"
          predicates:
            - Path=/api/qc/**
          filters:
            - AuthFilter
```

**Why two routes?**
- Spring Cloud Gateway's `Path=/api/qc/**` predicate does **not** match the exact path `/api/qc` (without a trailing segment). It only matches `/api/qc/something`.
- The frontend calls `GET /api/qc` (the same path the old mock served). Without the first route, that request hits no route and returns 404.
- `qc-service-root` catches exactly `/api/qc` and rewrites it to `/api/qc/inspections` where the real controller lives.
- `qc-service` handles all sub-path calls (`GET /api/qc/inspections/1`, `POST /api/qc/inspections`, etc.) and forwards them as-is.

**Other key points:**
- `${QC_SERVICE_URL:http://qc-service:8086}` — reads from env var with a fallback default. The env var is injected via the Helm configmap.
- `AuthFilter` — all routes except `/api/auth/**` require a valid JWT token.

### 5.2 Add QC_SERVICE_URL to api-gateway Helm values

Add `QC_SERVICE_URL` to the `configmap` section in all three api-gateway values files:

**Files to update:**
- `zen-gitops/envs/dev/values-api-gateway.yaml`
- `zen-gitops/envs/qa/values-api-gateway.yaml`
- `zen-gitops/envs/prod/values-api-gateway.yaml`

**Line to add in each file (under the existing service URLs in `configmap`):**

```yaml
  QC_SERVICE_URL: "http://qc-service:8086"
```

The Kubernetes service name `qc-service` resolves within the cluster because the `fullnameOverride` in the qc-service Helm values is set to `qc-service`.

---

## Step 6 — Create ArgoCD Application Manifests (zen-gitops)

ArgoCD watches these manifests and syncs the cluster state to match the Helm values files.

### 6.1 DEV application

**File:** `zen-gitops/argocd/apps/dev/qc-service-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: qc-service-dev
  namespace: argocd
  labels:
    env: dev
    app: qc-service
    managed-by: terraform
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: pharma
  source:
    repoURL: https://github.com/ravdy/zen-gitops.git
    targetRevision: HEAD
    path: helm-charts
    helm:
      valueFiles:
        - ../envs/dev/values-qc-service.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 6.2 QA application

**File:** `zen-gitops/argocd/apps/qa/qc-service-app.yaml`

Same as DEV with these differences:

```yaml
metadata:
  name: qc-service-qa
  labels:
    env: qa
spec:
  source:
    helm:
      valueFiles:
        - ../envs/qa/values-qc-service.yaml
  destination:
    namespace: qa
```

### 6.3 PROD application

**File:** `zen-gitops/argocd/apps/prod/qc-service-app.yaml`

Same as DEV with these differences:

```yaml
metadata:
  name: qc-service-prod
  labels:
    env: prod
spec:
  source:
    helm:
      valueFiles:
        - ../envs/prod/values-qc-service.yaml
  destination:
    namespace: prod
```

> **Important — repoURL must match exactly:**
> The `repoURL` value must exactly match what is listed in `argocd/projects/pharma-project.yaml` under `sourceRepos`. It is a plain string — ArgoCD does **not** do variable substitution here. If you use a placeholder like `your-github-username` it will fail with "not permitted in project" even if the rest of the config is correct.

### 6.4 Apply the ArgoCD applications

```bash
kubectl apply -f zen-gitops/argocd/apps/dev/qc-service-app.yaml
kubectl apply -f zen-gitops/argocd/apps/qa/qc-service-app.yaml
kubectl apply -f zen-gitops/argocd/apps/prod/qc-service-app.yaml
```

---

## Step 7 — Commit and Push GitOps Changes

```bash
cd zen-gitops

git add envs/dev/values-qc-service.yaml \
        envs/qa/values-qc-service.yaml \
        envs/prod/values-qc-service.yaml \
        envs/dev/values-api-gateway.yaml \
        envs/qa/values-api-gateway.yaml \
        envs/prod/values-api-gateway.yaml \
        argocd/apps/dev/qc-service-app.yaml \
        argocd/apps/qa/qc-service-app.yaml \
        argocd/apps/prod/qc-service-app.yaml

git commit -m "feat(qc-service): add helm values, argocd apps, and api-gateway routing"
git push
```

ArgoCD polls the gitops repo and will auto-sync within ~3 minutes of the push.

---

## Step 8 — Verify the Deployment

### 8.1 Check ArgoCD sync status

```bash
kubectl get application -n argocd | grep qc-service
```

Expected output:
```
qc-service-dev   Synced   Healthy   ...
```

### 8.2 Check pods are running

```bash
kubectl get pods -n dev -l app.kubernetes.io/name=qc-service
```

### 8.3 Check health endpoint directly

```bash
kubectl port-forward -n dev svc/qc-service 8086:8086
curl http://localhost:8086/actuator/health
```

Expected:
```json
{"status":"UP"}
```

### 8.4 Check end-to-end via api-gateway

```bash
# Get a JWT token first
TOKEN=$(curl -s -X POST http://<gateway-url>/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' | jq -r '.token')

# Hit qc-service through the gateway
curl -H "Authorization: Bearer $TOKEN" \
  http://<gateway-url>/api/qc/actuator/health
```

---

## Promotion Flow

```
Developer pushes to develop
        │
        ▼
ci-qc-service.yml triggered
  ├─ Maven build + tests (H2 in-memory, no DB container)
  ├─ CodeQL + Semgrep SAST
  ├─ Docker build + Trivy scan
  ├─ Push image to ECR → sha-<7chars>
  ├─ Update envs/dev/values-qc-service.yaml in zen-gitops
  │       └─ ArgoCD auto-syncs → DEV deployed
  └─ Open PR: promote/qa/qc-service/sha-<7chars> in zen-gitops
              └─ Team reviews and merges
                      └─ ArgoCD auto-syncs → QA deployed
                              └─ promote-prod.yml (manual workflow_dispatch)
                                      └─ ArgoCD auto-syncs → PROD deployed
```

---

## Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `application repo ... is not permitted in project 'pharma'` | `repoURL` in ArgoCD app manifest is a placeholder or wrong value | Set `repoURL` to the exact URL listed in `argocd/projects/pharma-project.yaml` under `sourceRepos` |
| Pod stuck in `ImagePullBackOff` | ECR repo doesn't exist yet or image tag is wrong | Run Terraform apply first; confirm image was pushed by CI |
| Pod `CrashLoopBackOff` | Application failed to start | Run `kubectl logs -n dev <pod-name>` to see Spring Boot startup errors |
| ArgoCD shows `OutOfSync` but won't sync | Values file not committed to gitops repo | Push values files and ArgoCD app manifests to zen-gitops |
| Gateway returns 404 for `/api/qc` | `Path=/api/qc/**` does not match the exact path `/api/qc` — missing `qc-service-root` route or gateway not redeployed yet | Add both routes (root + wildcard) to `application.yml`, commit and push — CI redeploys the gateway automatically |
| Gateway returns 404 for `/api/qc/inspections` | `qc-service` wildcard route not added to `application.yml` or gateway not redeployed | Add route, commit, push — gateway CI pipeline redeploys automatically |
