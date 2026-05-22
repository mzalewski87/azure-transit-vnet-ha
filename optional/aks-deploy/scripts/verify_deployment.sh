#!/usr/bin/env bash
###############################################################################
# verify_deployment.sh
#
# Smoke tests for the optional/aks-deploy/ Terraform module. Invoked by
# null_resource.smoke_tests as the final step of `terraform apply`. Exits
# non-zero (and therefore fails the apply) if any critical check fails.
#
# Environment expected (set by the null_resource local-exec):
#   CLUSTER_NAME            — AKS cluster name
#   CLUSTER_RG              — Resource group containing the AKS cluster
#   EDL_IP                  — Private IP of the EDL nginx server
#   WORDPRESS_URL           — Full HTTPS URL of the AFD endpoint
#   FW_MGMT_IP              — One FW's MGMT IP (used to verify EDL reachable
#                             FROM the FW perspective — optional, skipped
#                             if not set)
#
# Exit codes:
#   0 — all critical checks passed
#   1 — at least one critical check failed
#
# Non-critical checks (LB warm-up, AFD origin probe) print warnings but do
# not fail. The principle: only fail if the deployment is functionally broken,
# not just slow to settle.
###############################################################################

set -u
set -o pipefail

LOG="/tmp/aks-deploy-verify.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== verify_deployment.sh starting $(date -Is) ==="

FAIL=0
WARN=0

check() {
  local desc="$1"
  shift
  echo ""
  echo "----- $desc -----"
  if "$@"; then
    echo "  [OK] $desc"
  else
    echo "  [FAIL] $desc (exit $?)"
    FAIL=$((FAIL+1))
  fi
}

warn_check() {
  local desc="$1"
  shift
  echo ""
  echo "----- $desc -----"
  if "$@"; then
    echo "  [OK] $desc"
  else
    echo "  [WARN] $desc (exit $?)"
    WARN=$((WARN+1))
  fi
}

# ---- 1. AKS cluster reachable + nodes Ready ----
check "az aks get-credentials" \
  az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$CLUSTER_RG" --overwrite-existing --only-show-errors

check "kubectl nodes Ready" \
  kubectl wait --for=condition=Ready node --all --timeout=300s

# ---- 2. WordPress + ingress + MariaDB pods Running ----
echo ""
echo "----- Waiting up to 6 min for WordPress / MariaDB / ingress pods to be Running -----"
WP_OK=0
for i in $(seq 1 36); do
  NOT_RUN=$(kubectl get pods -A -o jsonpath='{.items[?(@.metadata.namespace=="wordpress" || @.metadata.namespace=="ingress-nginx")].status.phase}' \
    | tr ' ' '\n' | grep -vc '^Running$' || true)
  if [ "$NOT_RUN" = "0" ]; then
    WP_OK=1
    break
  fi
  echo "  [$i/36] $NOT_RUN pod(s) not yet Running — wait 10s..."
  sleep 10
done
if [ "$WP_OK" = "1" ]; then
  echo "  [OK] all wordpress/ingress-nginx pods Running"
else
  echo "  [FAIL] some pods still not Running after 6 min:"
  kubectl get pods -A | grep -E '(wordpress|ingress-nginx)' | grep -v Running || true
  FAIL=$((FAIL+1))
fi

# Image pull errors are the canonical symptom of EDL/FW rules not letting
# the cluster reach MCR/docker.io. Surface them explicitly.
check "no ImagePullBackOff in wordpress/ingress-nginx namespaces" \
  bash -c '! kubectl get pods -A -o jsonpath="{range .items[*]}{.metadata.namespace}/{.metadata.name} {range .status.containerStatuses[*]}{.state.waiting.reason}{end}{\"\n\"}{end}" 2>/dev/null | grep -E "(wordpress|ingress-nginx).*ImagePullBackOff"'

# ---- 3. EDL server still serving the FQDN + IP lists ----
check "EDL FQDN list reachable (curl http://$EDL_IP/edl/aks-egress-fqdn.txt)" \
  bash -c "curl -fsS --max-time 10 'http://$EDL_IP/edl/aks-egress-fqdn.txt' | grep -q 'mcr.microsoft.com'"

check "EDL IP list reachable (curl http://$EDL_IP/edl/aks-egress-ips.txt)" \
  bash -c "curl -fsS --max-time 10 'http://$EDL_IP/edl/aks-egress-ips.txt' | wc -l | awk '{exit (\$1 < 20)}'"

# ---- 4. WordPress reachable through AFD ----
# AFD origin health probe takes ~3 min to mark the origin healthy after first
# create. Allow up to 5 min with 30s polls.
echo ""
echo "----- Waiting up to 5 min for WordPress reachable via AFD ($WORDPRESS_URL) -----"
WP_REACH=0
for i in $(seq 1 10); do
  # WordPress installer page contains 'WordPress' near the title; the regular
  # blog page also contains it. Either match means the chain is working.
  if curl -fsSL --max-time 15 "$WORDPRESS_URL" 2>/dev/null | grep -qi 'wordpress'; then
    WP_REACH=1
    break
  fi
  echo "  [$i/10] WordPress not yet reachable via AFD — wait 30s..."
  sleep 30
done
if [ "$WP_REACH" = "1" ]; then
  echo "  [OK] WordPress responding through AFD"
else
  echo "  [FAIL] WordPress NOT reachable via AFD after 5 min"
  echo "    Common causes:"
  echo "      - AFD origin health probe still failing (Azure Portal: AFD → Origin Groups → og-aks-wordpress → Origin status)"
  echo "      - LB rule 8080 not yet active on External LB (Azure Portal: lb-external-panos → Load balancing rules)"
  echo "      - Panorama DNAT rule not pushed to FW (Panorama → Monitor → Traffic, filter rule=DNAT-Inbound-WordPress)"
  echo "      - FW security rule Allow-Inbound-WordPress denied — check Panorama Monitor → Traffic filter destination port=8080"
  FAIL=$((FAIL+1))
fi

# ---- 5. Optional: WordPress install page is present (not failing) ----
warn_check "WordPress wp-login.php reachable (post-install check)" \
  bash -c "curl -fsSL --max-time 15 '$WORDPRESS_URL/wp-login.php' | grep -qi 'log in\\|wordpress'"

echo ""
echo "=== verify_deployment.sh finished $(date -Is) ==="
echo "  Critical failures: $FAIL"
echo "  Warnings:          $WARN"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Deployment FAILED smoke tests. See $LOG for details."
  exit 1
fi
exit 0
