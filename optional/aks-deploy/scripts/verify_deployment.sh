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
# NOTE: `date -Is` is GNU-only (fails on macOS) — use a portable format.
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "=== verify_deployment.sh starting $(ts) ==="

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
  # One query per namespace: kubectl jsonpath has no `||` operator (an earlier
  # version of this check errored out and still reported OK). Count pods that
  # are not Running, plus 1 for each namespace that has no pods yet.
  NOT_RUN=$( { for ns in wordpress ingress-nginx; do
      kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null
      echo "__ns_done__"
    done; } | awk '
      $0=="__ns_done__" { if (!seen) bad++; seen=0; next }
      NF                { seen=1; if ($0!="Running") bad++ }
      END               { print bad+0 }')
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
# The EDL server has a PRIVATE IP in the management VNet. This script runs on
# the operator's workstation, which normally has no route there — a timeout
# here does NOT mean the EDL is broken. So these are warnings, not failures.
# Verify properly from inside the VNet: Panorama EDL status (Objects → External
# Dynamic Lists → Test Source URL) or via a Bastion tunnel (see docs/aks-runbook.md).
warn_check "EDL FQDN list reachable from this host (private IP; needs VNet route)" \
  bash -c "curl -fsS --max-time 10 'http://$EDL_IP/edl/aks-egress-fqdn.txt' | grep -q 'mcr.microsoft.com'"

warn_check "EDL IP list reachable from this host (private IP; needs VNet route)" \
  bash -c "curl -fsS --max-time 10 'http://$EDL_IP/edl/aks-egress-ips.txt' | wc -l | awk '{exit (\$1 < 20)}'"

# ---- 4. WordPress reachable through AFD ----
# A NEW AFD endpoint needs up to ~20 min to propagate to all edge POPs (until
# then AFD itself answers 404 "Page not found" without contacting the origin),
# and the origin health probe needs a few minutes on top. Allow up to 18 min
# with 30s polls.
echo ""
echo "----- Waiting up to 18 min for WordPress reachable via AFD ($WORDPRESS_URL) -----"
WP_REACH=0
for i in $(seq 1 36); do
  # WordPress installer page contains 'WordPress' near the title; the regular
  # blog page also contains it. Either match means the chain is working.
  if curl -fsSL --max-time 15 "$WORDPRESS_URL" 2>/dev/null | grep -qi 'wordpress'; then
    WP_REACH=1
    break
  fi
  echo "  [$i/36] WordPress not yet reachable via AFD — wait 30s..."
  sleep 30
done
if [ "$WP_REACH" = "1" ]; then
  echo "  [OK] WordPress responding through AFD"
else
  echo "  [FAIL] WordPress NOT reachable via AFD after 18 min"
  echo "    NOTE: testing from a corporate network? A corporate proxy may block"
  echo "    direct :8080 requests ('Web Page Blocked') — test via the AFD URL, not the LB IP."
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
echo "=== verify_deployment.sh finished $(ts) ==="
echo "  Critical failures: $FAIL"
echo "  Warnings:          $WARN"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Deployment FAILED smoke tests. See $LOG for details."
  exit 1
fi
exit 0
