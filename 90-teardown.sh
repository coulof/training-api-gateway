#!/usr/bin/env bash
#
# 90-teardown.sh — remove lab resources.
#
# Audience : participant or instructor
# Runs on  : anywhere with the lab kubeconfig.
#
#   ./90-teardown.sh              # remove lab namespaces and routes
#   ./90-teardown.sh --all        # also remove the HelmChartConfig  (READ THE WARNING)
#
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ALL=no
[[ "${1:-}" == "--all" ]] && ALL=yes

require_cmd kubectl "Install kubectl."
require_kubeconfig

log "deleting lab namespaces"
kubectl delete namespace "${DEMO_NS}" "${INFRA_NS}" "${TENANT_A}" "${TENANT_B}" \
  --ignore-not-found --wait=false

if [[ "$ALL" == yes ]]; then
  cat <<'BANNER'

  ⚠  STOP AND READ.

  Removing the HelmChartConfig disables Traefik's Gateway API provider.

  On RKE2 releases older than the April 2026 patches (v1.33.11+rke2r1,
  v1.34.7+rke2r1, v1.35.4+rke2r1), that DELETES the Gateway API CRDs and every
  Gateway and Route in the cluster — including any outside this lab.

  On a disposable lab cluster this is fine. On anything else it is not.

BANNER
  read -r -p "  Type 'disposable' to continue: " confirm
  if [[ "$confirm" != "disposable" ]]; then
    warn "aborted — HelmChartConfig left in place"
    exit 0
  fi
  log "removing HelmChartConfig rke2-traefik"
  kubectl -n kube-system delete helmchartconfig rke2-traefik --ignore-not-found
  warn "Traefik will now redeploy without the Gateway provider."
fi

log "remaining lab resources"
kubectl get gateway,httproute,grpcroute,referencegrant -A 2>/dev/null | grep -v '^$' || info "none"

cat <<TIP

Your own YAML in ~/lab is untouched — that is the record of the session.
Delete it yourself if you want it gone:  rm -rf ~/lab

To destroy the whole cluster, ask the instructor; it is a VM, not a kubectl call.
TIP
