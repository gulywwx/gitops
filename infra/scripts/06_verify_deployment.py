#!/usr/bin/env python3
# =============================================================================
# Stage 4 - Verify Deployment
#
# Runs health checks to confirm everything is working:
#   1. Kubernetes pods  - all Running and Ready
#   2. ArgoCD apps      - all Synced and Healthy
#   3. External Secrets - all SecretSynced
#   4. Services/Ingress - resources created
#   5. HTTP endpoints   - health checks via ALB
#
# Run from the root of the dpp-assignment3 directory.
# =============================================================================

import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
BLUE   = "\033[0;34m"
NC     = "\033[0m"

def _ts():
    return datetime.now().strftime("%H:%M:%S")

def log(msg):   print(f"{GREEN}[{_ts()}] OK  {msg}{NC}")
def warn(msg):  print(f"{YELLOW}[{_ts()}] !!  {msg}{NC}")
def info(msg):  print(f"{BLUE}[{_ts()}]    {msg}{NC}")
def die(msg):
    print(f"{RED}[{_ts()}] ERR {msg}{NC}", file=sys.stderr)
    sys.exit(1)

ERRORS = 0

def fail(msg):
    global ERRORS
    print(f"{RED}[{_ts()}] FAIL {msg}{NC}", file=sys.stderr)
    ERRORS += 1

def run_cmd(args, ok_fail=False, capture=False):
    if capture:
        result = subprocess.run(args, capture_output=True, text=True)
        return result.stdout.strip(), result.returncode
    result = subprocess.run(args)
    if result.returncode != 0 and not ok_fail:
        die(f"Command failed: {' '.join(str(a) for a in args)}")
    return None, result.returncode

# ---------------------------------------------------------------------------
# Verify tools
# ---------------------------------------------------------------------------
if subprocess.run(["which", "kubectl"], capture_output=True).returncode != 0:
    die("kubectl not found.")

# ---------------------------------------------------------------------------
# Collect inputs
# ---------------------------------------------------------------------------
print()
print("============================================")
print("  Zen Pharma -- Deployment Verification")
print("============================================")
print()
print("  This script checks that all services are healthy in a given environment.")
print()

ENV = os.environ.get("ENV", "")

if not ENV:
    print(f"{CYAN}  Target environment (which namespace to check){NC}")
    print("    1) dev   - development environment")
    print("    2) qa    - quality assurance environment")
    print("    3) prod  - production environment")
    raw = input("    Enter number [1]: ").strip() or "1"
    ENV = {"1": "dev", "2": "qa", "3": "prod"}.get(raw)
    if not ENV:
        die(f"Invalid choice '{raw}'.")

if ENV not in ("dev", "qa", "prod"):
    die("ENV must be dev, qa, or prod.")

TIMEOUT_PODS = int(os.environ.get("TIMEOUT_PODS", "300"))
ARGOCD_NS    = "argocd"

print()
print(f"  Environment : {ENV}")
print()

# ---------------------------------------------------------------------------
# Check 1 - Kubernetes Pods
# ---------------------------------------------------------------------------
print("--------------------------------------------")
print(f"  Check 1 of 5: Kubernetes Pods (namespace: {ENV})")
print("--------------------------------------------")

info(f"Waiting up to 60s for pods to appear in namespace '{ENV}'...")
elapsed = 0
pod_count = 0

while elapsed < 60:
    pods_out, _ = run_cmd(
        ["kubectl", "get", "pods", "-n", ENV, "--no-headers"],
        capture=True, ok_fail=True,
    )
    pod_count = len([l for l in pods_out.splitlines() if l.strip()])
    if pod_count > 0:
        break
    print(f"  No pods yet in '{ENV}' ({elapsed}s elapsed) -- ArgoCD may still be syncing...")
    time.sleep(10)
    elapsed += 10

if elapsed >= 60:
    warn(f"No pods found in '{ENV}' after 60s.")
    warn("  ArgoCD may not have synced yet. Check: kubectl get applications -n argocd")
else:
    # `kubectl wait pod --all` resolves the pod list once, then blocks on those
    # exact names. An ArgoCD rollout deletes old-generation pods mid-wait, so
    # the snapshotted names 404 and the command exits non-zero even though every
    # Deployment converged cleanly. Wait on the workload instead: `rollout
    # status` is generation-aware and unaffected by pod churn.
    deploys_out, _ = run_cmd(
        ["kubectl", "get", "deployments", "-n", ENV,
         "-o", "jsonpath={.items[*].metadata.name}"],
        capture=True, ok_fail=True,
    )
    deployments = deploys_out.split()

    if not deployments:
        warn(f"No Deployments found in '{ENV}' -- cannot verify rollout convergence.")
    else:
        info(f"Waiting up to {TIMEOUT_PODS}s for {len(deployments)} deployment(s) to converge...")
        # One shared budget across all deployments, matching the semantics of the
        # single --timeout the previous kubectl wait used.
        deadline = time.monotonic() + TIMEOUT_PODS
        stalled = []
        for name in deployments:
            remaining = max(1, int(deadline - time.monotonic()))
            _, rc = run_cmd(
                ["kubectl", "rollout", "status", f"deployment/{name}",
                 "-n", ENV, f"--timeout={remaining}s"],
                ok_fail=True,
            )
            if rc != 0:
                stalled.append(name)
                fail(f"Deployment '{name}' did not converge within the timeout.")
        if not stalled:
            log(f"All {len(deployments)} deployments converged; pods are Running and Ready.")

print()
run_cmd(["kubectl", "get", "pods", "-n", ENV, "-o", "wide"])
print()

# ---------------------------------------------------------------------------
# Check 2 - ArgoCD Application health
# ---------------------------------------------------------------------------
print("--------------------------------------------")
print("  Check 2 of 5: ArgoCD Application Status")
print("--------------------------------------------")
print()

run_cmd(["kubectl", "get", "applications", "-n", ARGOCD_NS, "-o", "wide"], ok_fail=True)
print()

apps_out, _ = run_cmd(
    ["kubectl", "get", "applications", "-n", ARGOCD_NS, "--no-headers"],
    capture=True, ok_fail=True,
)
for line in apps_out.splitlines():
    parts = line.split()
    if len(parts) >= 4:
        app_name    = parts[0]
        sync_status = parts[2]
        health      = parts[3]
        if sync_status != "Synced" or health != "Healthy":
            fail(f"App '{app_name}': sync={sync_status}, health={health}")

if ERRORS == 0:
    log("All ArgoCD applications are Synced and Healthy.")

# ---------------------------------------------------------------------------
# Check 3 - External Secrets
# ---------------------------------------------------------------------------
print("--------------------------------------------")
print("  Check 3 of 5: External Secrets")
print("--------------------------------------------")
print()

run_cmd(["kubectl", "get", "externalsecret", "-n", ENV], ok_fail=True)
print()

# The printed columns differ between ESO versions - newer builds insert
# STORETYPE and append LAST SYNC, so a fixed column index reads STATUS and
# reports a healthy SecretSynced secret as not Ready. Ask for the condition.
es_names, _ = run_cmd(
    ["kubectl", "get", "externalsecret", "-n", ENV,
     "-o", "jsonpath={.items[*].metadata.name}"],
    capture=True, ok_fail=True,
)
for es_name in es_names.split():
    es_ready, _ = run_cmd(
        ["kubectl", "get", "externalsecret", es_name, "-n", ENV,
         "-o", 'jsonpath={.status.conditions[?(@.type=="Ready")].status}'],
        capture=True, ok_fail=True,
    )
    if es_ready != "True":
        fail(f"ExternalSecret '{es_name}' is not Ready (Ready={es_ready or 'Unknown'})")

if ERRORS == 0:
    log("All ExternalSecrets are synced.")

# ---------------------------------------------------------------------------
# Check 4 - Services and Ingress
# ---------------------------------------------------------------------------
print("--------------------------------------------")
print("  Check 4 of 5: Services and Ingress")
print("--------------------------------------------")
print()

run_cmd(["kubectl", "get", "svc", "-n", ENV])
print()
run_cmd(["kubectl", "get", "ingress", "-n", ENV], ok_fail=True)
print()

# ALB hostname is provisioned per-Ingress by the AWS Load Balancer Controller.
# We read it from the pharma-ui ingress (the group's primary entry point).
alb_hostname, _ = run_cmd(
    ["kubectl", "get", "ingress", "pharma-ui", "-n", ENV,
     "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"],
    capture=True, ok_fail=True,
)

if not alb_hostname:
    # Fallback: try any ingress in the namespace
    alb_hostname, _ = run_cmd(
        ["kubectl", "get", "ingress", "-n", ENV,
         "-o", "jsonpath={.items[0].status.loadBalancer.ingress[0].hostname}"],
        capture=True, ok_fail=True,
    )

if alb_hostname:
    log(f"ALB hostname: {alb_hostname}")
else:
    warn("ALB hostname not available yet -- the AWS Load Balancer Controller may still be provisioning.")
    warn("  Check: kubectl get ingress -n " + ENV)

# ---------------------------------------------------------------------------
# Check 5 - Service health
# ---------------------------------------------------------------------------
print("--------------------------------------------")
print("  Check 5 of 5: Service Health")
print("--------------------------------------------")
print()

# Actuator is not routed through the gateway, and that is the correct posture -
# nobody should be able to read /actuator from the internet. Probing it through
# the ALB returns 404 for the services the gateway routes by prefix and 401 for
# the ones behind its JWT filter, and neither answer says anything about whether
# the service is well. So ask each Service directly from inside the cluster,
# which is the same question the readiness probe asks.
SERVICE_ENDPOINTS = [
    ("api-gateway",           8080),
    ("auth-service",          8081),
    ("drug-catalog-service",  8082),
    ("inventory-service",     8083),
    ("supplier-service",      8084),
    ("manufacturing-service", 8085),
    ("qc-service",            8086),
    ("notification-service",  3000),
]

targets   = " ".join(f"{n}:{p}" for n, p in SERVICE_ENDPOINTS)
probe_sh  = (
    f'for s in {targets}; do '
    'n=${s%%:*}; '
    'c=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$s/actuator/health"); '
    'echo "$n $c"; done'
)

info("Probing /actuator/health from inside the cluster...")
probe_out, probe_rc = run_cmd(
    ["kubectl", "run", "verify-health-probe", "--rm", "-i", "--restart=Never",
     "--image=curlimages/curl:8.10.1", "-n", ENV, "--timeout=120s",
     "--", "sh", "-c", probe_sh],
    capture=True, ok_fail=True,
)

# --rm -i can fall back to streaming logs and repeat the output, so the results
# are collected into a dict rather than counted line by line.
seen = {}
for line in probe_out.splitlines():
    parts = line.split()
    if len(parts) == 2 and parts[1].isdigit():
        seen[parts[0]] = parts[1]

if not seen:
    fail("Could not probe service health - the curl pod produced no output.")
    if probe_rc != 0:
        warn("  kubectl run failed. Check that nodes can pull curlimages/curl.")
else:
    for service, _ in SERVICE_ENDPOINTS:
        code = seen.get(service)
        if code is None:
            fail(f"{service}: no response from the probe")
        elif code == "200":
            log(f"{service}: HTTP {code}  <--  /actuator/health")
        else:
            fail(f"{service}: HTTP {code}  <--  /actuator/health  (expected 200)")

# The frontend is the one thing that genuinely has to answer from the internet.
if alb_hostname:
    print()
    url = f"http://{alb_hostname}/"
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=10) as resp:
            http_code = resp.status
    except urllib.error.HTTPError as e:
        http_code = e.code
    except Exception:
        http_code = 0

    if http_code in (200, 301, 302):
        log(f"pharma-ui: HTTP {http_code}  <--  {url}  (public)")
    else:
        fail(f"pharma-ui: HTTP {http_code}  <--  {url}  (expected 200/301/302)")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print()
print("============================================")
if ERRORS == 0:
    print(f"{GREEN}  ALL CHECKS PASSED{NC}")
    print()
    if alb_hostname:
        print(f"  Application URL : http://{alb_hostname}/")
    print("  ArgoCD UI       : https://localhost:8080")
    print("                    (kubectl port-forward svc/argocd-server -n argocd 8080:443)")
else:
    print(f"{RED}  {ERRORS} CHECK(S) FAILED{NC}")
    print()
    print("  Troubleshooting commands:")
    print(f"    kubectl describe pod <pod-name> -n {ENV}")
    print(f"    kubectl logs -n {ENV} deployment/<service-name> --previous")
    print(f"    kubectl describe externalsecret db-credentials -n {ENV}")
    print("    kubectl get applications -n argocd")
print("============================================")
print()

sys.exit(ERRORS)
