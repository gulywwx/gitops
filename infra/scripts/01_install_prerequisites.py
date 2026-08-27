#!/usr/bin/env python3
# =============================================================================
# Stage 2 - Install Kubernetes Pre-requisites
#
# Installs on the EKS cluster (must already exist from Stage 1 Terraform):
#   1. Gateway API CRDs             - upstream + the AWS controller's own
#   2. AWS Load Balancer Controller - turns Gateways into AWS ALBs
#   3. ArgoCD                       - GitOps CD controller
#   4. External Secrets Operator    - syncs AWS Secrets Manager -> K8s Secrets
#
# Run from anywhere — paths are resolved relative to this script's location.
# =============================================================================

import base64
import os
import subprocess
import sys
import time
from datetime import datetime
from string import Template

# Repo root is two levels above this script: infra/scripts/ -> infra/ -> repo root.
# This repo IS the gitops repo, so the repo root is also the default GITOPS_PATH.
DEFAULT_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Bootstrap assets are resolved from this script's own location rather than from
# GITOPS_PATH. They are applied imperatively and ArgoCD never sees them, so they
# do not belong to the GitOps tree and must not follow it if it is relocated.
BOOTSTRAP_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bootstrap")


# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
NC     = "\033[0m"

def _ts():
    return datetime.now().strftime("%H:%M:%S")

def log(msg):   print(f"{GREEN}[{_ts()}] OK  {msg}{NC}")
def warn(msg):  print(f"{YELLOW}[{_ts()}] !!  {msg}{NC}")
def info(msg):  print(f"{CYAN}[{_ts()}]    {msg}{NC}")
def die(msg):
    print(f"{RED}[{_ts()}] ERR {msg}{NC}", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# run_cmd: run a shell command, streaming output; die on failure unless ok_fail=True
# ---------------------------------------------------------------------------
def run_cmd(args, ok_fail=False, capture=False):
    if capture:
        result = subprocess.run(args, capture_output=True, text=True)
        return result.stdout.strip(), result.returncode
    result = subprocess.run(args)
    if result.returncode != 0 and not ok_fail:
        die(f"Command failed: {' '.join(str(a) for a in args)}")
    return None, result.returncode

# ---------------------------------------------------------------------------
# prompt: ask the user for a value, skip if already in environment
# ---------------------------------------------------------------------------
def prompt(var_name, label, example, default=""):
    current = os.environ.get(var_name, "")
    if current:
        info(f"Using {var_name}={current}  (pre-set in environment, skipping prompt)")
        return current

    print()
    print(f"{CYAN}  {label}{NC}")
    print(f"    Example : {example}")

    if default:
        print(f"    Default : {default}")
        raw = input("    Your value [press Enter to use default]: ").strip()
    else:
        raw = input("    Your value: ").strip()

    value = raw if raw else default
    if not value:
        die(f"'{label}' is required and cannot be empty.")

    log(f"  {var_name} = {value}")
    return value

# ---------------------------------------------------------------------------
# apply_rendered: substitute ${PLACEHOLDER} tokens in a manifest, then apply it
#
# The Gateway manifests carry two values that only exist after terraform runs -
# the base domain and the ACM certificate ARN - so they cannot be committed as
# literal YAML. string.Template is used rather than str.format because the
# manifests contain YAML braces that format() would try to interpret.
# ---------------------------------------------------------------------------
def apply_rendered(path, **substitutions):
    if not os.path.isfile(path):
        die(f"Manifest not found: {path}")

    with open(path) as fh:
        rendered = Template(fh.read()).substitute(**substitutions)

    result = subprocess.run(["kubectl", "apply", "-f", "-"],
                            input=rendered, text=True)
    if result.returncode != 0:
        die(f"Failed to apply {path}")

# ---------------------------------------------------------------------------
# Verify required tools are installed
# ---------------------------------------------------------------------------
print()
print("Checking required tools...")
for tool in ["kubectl", "helm", "aws"]:
    rc = subprocess.run(["which", tool], capture_output=True).returncode
    if rc != 0:
        die(f"{tool} not found. Install it before running this script.")
log("kubectl, helm, and aws CLI found.")

# ---------------------------------------------------------------------------
# Collect inputs
# ---------------------------------------------------------------------------
print()
print("============================================")
print("  Zen Pharma -- Pre-requisites Installer")
print("============================================")
print()
print("  This script installs AWS Load Balancer Controller, ArgoCD, and")
print("  External Secrets Operator on your EKS cluster using Helm.")
print()
print("  You will be asked for 6 values:")
print("    1. EKS cluster name         - from Terraform outputs or AWS console")
print("    2. AWS region               - where your cluster is running")
print("    3. VPC ID                   - VPC where the cluster lives (auto-fetched if blank)")
print("    4. ALB controller role ARN  - IAM role ARN for the ALB controller")
print("       (arn:aws:iam::<account-id>:role/<project>-<env>-alb-controller-role)")
print("    5. Base domain              - terraform output internal_domain")
print("    6. ACM certificate ARN      - terraform output acm_certificate_arn")
print()

CLUSTER_NAME        = prompt("CLUSTER_NAME",        "EKS cluster name",
                             "pharma-dev-cluster", "pharma-dev-cluster")
AWS_REGION          = prompt("AWS_REGION",          "AWS region where the cluster is deployed",
                             "us-east-1", "us-east-1")
ALB_CONTROLLER_ROLE = prompt("ALB_CONTROLLER_ROLE", "IAM role ARN for the AWS Load Balancer Controller",
                             "arn:aws:iam::<aws-account-id>:role/pharma-dev-alb-controller-role",
                             "arn:aws:iam::873135413040:role/pharma-dev-alb-controller-role")
BASE_DOMAIN         = prompt("BASE_DOMAIN",         "Base domain served by the shared Gateway",
                             "pharma.internal", "pharma.internal")
ACM_CERTIFICATE_ARN = prompt("ACM_CERTIFICATE_ARN", "ACM ARN of the self-signed wildcard certificate",
                             "arn:aws:acm:us-east-1:<aws-account-id>:certificate/<uuid>", "")

default_gitops = os.path.join(DEFAULT_PROJECT_ROOT, "gitops")
GITOPS_PATH         = prompt("GITOPS_PATH",         "Local path to your gitops repo",
                             default_gitops, default_gitops)

# Auto-fetch VPC ID from EKS cluster if not set in environment
VPC_ID = os.environ.get("VPC_ID", "")
if not VPC_ID:
    info(f"Auto-fetching VPC ID for cluster '{CLUSTER_NAME}'...")
    VPC_ID, rc = run_cmd(
        ["aws", "eks", "describe-cluster", "--name", CLUSTER_NAME,
         "--region", AWS_REGION,
         "--query", "cluster.resourcesVpcConfig.vpcId",
         "--output", "text"],
        capture=True, ok_fail=True,
    )
    if rc == 0 and VPC_ID and VPC_ID != "None":
        log(f"VPC ID auto-detected: {VPC_ID}")
    else:
        VPC_ID = prompt("VPC_ID", "VPC ID where the EKS cluster runs",
                        "vpc-xxxxxxxxxxxxxxxxx")

print()
print("  ----- Configuration Summary -----")
print(f"  Cluster          : {CLUSTER_NAME}")
print(f"  Region           : {AWS_REGION}")
print(f"  VPC ID           : {VPC_ID}")
print(f"  ALB role ARN     : {ALB_CONTROLLER_ROLE}")
print(f"  Base domain      : {BASE_DOMAIN}")
print(f"  Certificate ARN  : {ACM_CERTIFICATE_ARN}")
print("  ---------------------------------")
print()
confirm = input("  Proceed with installation? [Y/n]: ").strip() or "Y"
if confirm.upper() != "Y":
    print("Aborted.")
    sys.exit(0)
print()

# ---------------------------------------------------------------------------
# Configure kubectl
# ---------------------------------------------------------------------------
info(f"Updating kubeconfig for cluster '{CLUSTER_NAME}' in '{AWS_REGION}'...")
_, rc = run_cmd(
    ["aws", "eks", "update-kubeconfig", "--region", AWS_REGION, "--name", CLUSTER_NAME],
    ok_fail=True,
)
if rc != 0:
    warn("kubeconfig update failed - continuing with existing context")

ctx, _ = run_cmd(["kubectl", "config", "current-context"], capture=True)
log(f"kubectl context: {ctx}")

# ---------------------------------------------------------------------------
# Add Helm repositories
# ---------------------------------------------------------------------------
print()
info("Adding Helm repositories...")
for name, url in [
    ("eks",              "https://aws.github.io/eks-charts"),
    ("external-secrets", "https://charts.external-secrets.io"),
    ("argo",             "https://argoproj.github.io/argo-helm"),
]:
    run_cmd(["helm", "repo", "add", name, url, "--force-update"], ok_fail=True)
run_cmd(["helm", "repo", "update"])
log("Helm repos updated.")

# ---------------------------------------------------------------------------
# Step 1 - Upstream Gateway API CRDs
#
# The controller decides whether to run its Gateway reconciler by looking for
# these CRDs at boot, so they have to exist before the Helm install in step 2.
# Only the upstream half is installed here - the gateway.k8s.aws CRDs ship in
# the controller's own chart and are version-matched to it, so pulling those
# separately would only invite skew.
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 1 of 4: Gateway API CRDs")
print("--------------------------------------------")

GATEWAY_API_VERSION = "v1.6.0"

info(f"Installing upstream Gateway API CRDs ({GATEWAY_API_VERSION})...")
# Server-side apply: the CRD manifests exceed the 256 KB annotation limit that
# client-side apply uses to record last-applied-configuration.
run_cmd(["kubectl", "apply", "--server-side=true", "-f",
         "https://github.com/kubernetes-sigs/gateway-api/releases/download/"
         f"{GATEWAY_API_VERSION}/standard-install.yaml"])

run_cmd(["kubectl", "wait", "--for=condition=Established", "--timeout=120s",
         "crd/gatewayclasses.gateway.networking.k8s.io",
         "crd/gateways.gateway.networking.k8s.io",
         "crd/httproutes.gateway.networking.k8s.io"])
log("Upstream Gateway API CRDs established.")

# ---------------------------------------------------------------------------
# Step 2 - AWS Load Balancer Controller
#
# Watches Gateway and HTTPRoute resources whose GatewayClass names the
# gateway.k8s.aws/alb controller, and provisions one AWS Application Load
# Balancer per Gateway. Runs in kube-system and uses IRSA (IAM Roles for
# Service Accounts) to call AWS APIs.
#
# The chart's crds/ directory carries the gateway.k8s.aws CRDs, so this install
# is also what registers LoadBalancerConfiguration and TargetGroupConfiguration.
# Helm creates those on first install only and never touches them on upgrade,
# so bumping ALB_CHART_VERSION on a live cluster needs them applied by hand.
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 2 of 4: AWS Load Balancer Controller")
print("--------------------------------------------")

# Gateway API support is GA from controller v3.0.0. Pinning matters here in a
# way it did not before: an unpinned chart that resolves to something older
# would install a controller with no Gateway reconciler at all.
#
# ALBGatewayAPI is not passed as a feature gate because v3.5.0 already defaults
# it to true (pkg/config/feature_gates.go). The chart has no values schema, so
# a gate name that drifts would fail silently rather than loudly.
ALB_CHART_VERSION = "3.5.0"

alb_cmd = [
    "helm", "upgrade", "--install", "aws-load-balancer-controller",
    "eks/aws-load-balancer-controller",
    "--namespace", "kube-system",
    "--version", ALB_CHART_VERSION,
    "--set", f"clusterName={CLUSTER_NAME}",
    "--set", f"region={AWS_REGION}",
    "--set", f"vpcId={VPC_ID}",
    "--set", "serviceAccount.create=true",
    "--set", "serviceAccount.name=aws-load-balancer-controller",
    "--set", f"serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn={ALB_CONTROLLER_ROLE}",
    "--wait", "--timeout", "5m",
]

# Webhook configs orphaned by a failed previous install carry a caBundle from a
# cert that no longer exists. Clearing them BEFORE the install lets Helm recreate
# them in lockstep with the cert it is about to generate.
info("Clearing any stale ALB webhook configurations...")
for wh_type in ["mutatingwebhookconfiguration", "validatingwebhookconfiguration"]:
    run_cmd(["kubectl", "delete", wh_type, "aws-load-balancer-webhook",
             "--ignore-not-found"], ok_fail=True)

run_cmd(alb_cmd)
log("AWS Load Balancer Controller installed.")

run_cmd(["kubectl", "wait", "--for=condition=Established", "--timeout=120s",
         "crd/loadbalancerconfigurations.gateway.k8s.aws",
         "crd/targetgroupconfigurations.gateway.k8s.aws"])
log("AWS Gateway CRDs established.")

alb_version, _ = run_cmd(
    ["helm", "list", "-n", "kube-system", "--filter", "aws-load-balancer-controller",
     "--short"],
    capture=True, ok_fail=True,
)
log(f"Release: {alb_version or 'aws-load-balancer-controller'}")

# The webhook cert is generated by Helm at render time and written to BOTH the
# aws-load-balancer-tls Secret and the webhook caBundle. A `helm upgrade` rotates
# both instantly, but running pods keep serving the previous cert until the
# kubelet resyncs the mounted Secret (~60s), and every webhook call fails with
# x509 in that window. So never upgrade merely to refresh certs: restart the
# pods, then confirm the webhook actually answers before continuing.
info("Restarting ALB controller so it serves the current webhook cert...")
run_cmd(["kubectl", "rollout", "restart",
         "deployment/aws-load-balancer-controller", "-n", "kube-system"])
run_cmd(["kubectl", "rollout", "status",
         "deployment/aws-load-balancer-controller", "-n", "kube-system",
         "--timeout=3m"])

ALB_WEBHOOK_PROBE = """apiVersion: v1
kind: Service
metadata:
  name: alb-webhook-probe
  namespace: kube-system
spec:
  ports:
  - port: 80
  selector:
    app: alb-webhook-probe
"""

def wait_for_alb_webhook(timeout=180):
    # --dry-run=server runs the full admission chain (webhooks included) but
    # persists nothing, so this exercises the exact path ArgoCD's Service
    # creation will take without leaving an object to clean up.
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = subprocess.run(["kubectl", "apply", "--dry-run=server", "-f", "-"],
                               input=ALB_WEBHOOK_PROBE, text=True, capture_output=True)
        if probe.returncode == 0:
            log("ALB webhook verified - serving a trusted certificate.")
            return
        if "x509" not in probe.stderr and "webhook" not in probe.stderr:
            die(f"Unexpected error probing ALB webhook:\n{probe.stderr}")
        info("  Webhook cert still propagating, retrying in 10s...")
        time.sleep(10)
    die("ALB webhook did not become ready within 3m. Inspect with:\n"
        "  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller")

wait_for_alb_webhook()

# The Gateway objects go in only once the webhook answers: the controller
# validates LoadBalancerConfiguration and Gateway through that same admission
# path, and an apply that races it fails with x509 rather than a useful error.
info("Applying the shared Gateway...")
GATEWAY_DIR = os.path.join(BOOTSTRAP_DIR, "gateway")
for manifest in ["00-namespace.yaml", "10-gatewayclass.yaml",
                 "20-loadbalancer-config.yaml", "30-gateway.yaml"]:
    apply_rendered(
        os.path.join(GATEWAY_DIR, manifest),
        BASE_DOMAIN=BASE_DOMAIN,
        ACM_CERTIFICATE_ARN=ACM_CERTIFICATE_ARN,
    )
log(f"Shared Gateway applied - one ALB serves all of *.{BASE_DOMAIN}.")
print("  The ALB takes a few minutes to provision. Watch it with:")
print("    kubectl get gateway pharma-gateway -n gateway-system -w")

# ---------------------------------------------------------------------------
# Step 3 - ArgoCD
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 3 of 4: ArgoCD")
print("--------------------------------------------")

run_cmd([
    "helm", "upgrade", "--install", "argocd", "argo/argo-cd",
    "--namespace", "argocd",
    "--create-namespace",
    "--wait", "--timeout", "10m",
])

argocd_password_b64, _ = run_cmd(
    ["kubectl", "-n", "argocd", "get", "secret", "argocd-initial-admin-secret",
     "-o", "jsonpath={.data.password}"],
    capture=True,
)
argocd_password = base64.b64decode(argocd_password_b64).decode().strip()

log("ArgoCD installed.")
print()
print("  ============================================================")
print("  IMPORTANT: Save the ArgoCD credentials below")
print("  ============================================================")
print("  Username : admin")
print(f"  Password : {argocd_password}")
print()
print("  To access the ArgoCD UI:")
print(f"    https://argocd.{BASE_DOMAIN}   (after adding the ALB to /etc/hosts)")
print("    kubectl port-forward svc/argocd-server -n argocd 8080:443")
print("  ============================================================")
print()

apply_rendered(
    os.path.join(GITOPS_PATH, "argocd/install/argocd-httproute.yaml"),
    BASE_DOMAIN=BASE_DOMAIN,
)
log(f"ArgoCD route applied - argocd.{BASE_DOMAIN} attached to the shared Gateway.")

# ---------------------------------------------------------------------------
# Step 4 - External Secrets Operator
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 4 of 4: External Secrets Operator")
print("--------------------------------------------")

run_cmd([
    "helm", "upgrade", "--install", "external-secrets", "external-secrets/external-secrets",
    "--namespace", "external-secrets",
    "--create-namespace",
    "--set", "installCRDs=true",
    "--wait", "--timeout", "5m",
])

log("External Secrets Operator installed.")

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Verification")
print("--------------------------------------------")
print()
print("AWS Load Balancer Controller pods (namespace: kube-system):")
run_cmd(["kubectl", "get", "pods", "-n", "kube-system",
         "-l", "app.kubernetes.io/name=aws-load-balancer-controller"])
print()
print("ArgoCD pods (namespace: argocd):")
run_cmd(["kubectl", "get", "pods", "-n", "argocd"])
print()
print("External Secrets pods (namespace: external-secrets):")
run_cmd(["kubectl", "get", "pods", "-n", "external-secrets"])

print()
log("All pre-requisites installed successfully.")
print()
print("  Summary:")
print(f"    ALB controller   : installed in kube-system")
print(f"    Shared Gateway   : pharma-gateway in gateway-system")
print(f"    ArgoCD pass      : {argocd_password}")
print()
print("  One ALB fronts every route. Get its address with:")
print("    kubectl get gateway pharma-gateway -n gateway-system")
print()
print("  Then map it locally, since the domain is not publicly registered:")
print(f"    ALB=$(kubectl get gateway pharma-gateway -n gateway-system \\")
print(f"          -o jsonpath='{{.status.addresses[0].value}}')")
print(f"    echo \"$(dig +short $ALB | head -1) argocd.{BASE_DOMAIN} "
      f"dev.{BASE_DOMAIN} qa.{BASE_DOMAIN} prod.{BASE_DOMAIN}\" | sudo tee -a /etc/hosts")
print()
print("  The certificate is self-signed, so browsers warn once per hostname.")
print()
print("Next step: ./scripts/02_bootstrap_argocd.py")
