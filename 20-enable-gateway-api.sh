#!/usr/bin/env bash
#
# 20-enable-gateway-api.sh — enable Traefik's Gateway API provider.
#
# Audience : instructor (reset / recovery) — participants normally do this by
#            hand as Lab 3, because watching the CRDs appear is the point.
# Runs on  : anywhere with the lab kubeconfig. No node access needed.
#
#   ./20-enable-gateway-api.sh [--wait]
#
# Applies the HelmChartConfig with kubectl rather than dropping a file into
# /var/lib/rancher/rke2/server/manifests/. Both work; only this one works over
# a kubeconfig, which is why the lab uses it.
#
if [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
else
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

require_cmd kubectl "Install kubectl."
require_kubeconfig

title "Before"
if gateway_api_enabled; then
  warn "Gateway API CRDs already present — this run will be a no-op re-apply."
  info "bundle-version: $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo unknown)"
else
  info "No Gateway API CRDs yet."
fi
info "Traefik image: $(traefik_image)"
info "workload     : $(traefik_workload)"

cat <<'BANNER'

  ⚠  CRD DELETION WARNING — read before you ever reverse this.

  On RKE2 releases older than the April 2026 patches (v1.33.11+rke2r1,
  v1.34.7+rke2r1, v1.35.4+rke2r1), DISABLING Traefik after having enabled it
  removes the Gateway API CRDs — and every Gateway and Route with them.

  Do not disable Traefik or uninstall the traefik-crds AddOn while the cluster
  holds Gateway API resources you care about.

BANNER

title "Applying HelmChartConfig"

kubectl apply -f - <<'HCEOF'
---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      type: LoadBalancer
    providers:
      kubernetesGateway:
        enabled: true
        experimentalChannel: true
HCEOF

log "waiting for helm-controller to redeploy Traefik"
sleep 5
kubectl -n kube-system rollout status "$(traefik_workload)" --timeout=5m \
  || warn "Traefik rollout did not complete cleanly — inspect: kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik"

log "waiting for Gateway API CRDs"
for i in $(seq 1 60); do
  gateway_api_enabled && break
  sleep 5
  if [[ $i -eq 60 ]]; then
    die "Gateway API CRDs never appeared. Check the traefik-crds AddOn and the helm-controller job:
       kubectl -n kube-system get helmchart,helmchartconfig
       kubectl -n kube-system logs -l batch.kubernetes.io/job-name --tail=50"
  fi
done

log "waiting for a GatewayClass to be claimed"
for i in $(seq 1 30); do
  [[ -n "$(kubectl get gatewayclass -o name 2>/dev/null)" ]] && break
  sleep 5
  [[ $i -eq 30 ]] && warn "No GatewayClass yet — the provider may not have started"
done

title "After"

kubectl get crd | grep gateway.networking.k8s.io || true
echo
kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null || true
echo
kubectl get gatewayclass 2>/dev/null || true

BUNDLE=$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo unknown)
GWC=$(gwclass)

title "Checks"
check "Gateway API CRDs installed"      "gateway_api_enabled"
check "HTTPRoute served"                "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q httproutes"
check "GRPCRoute served (Lab 6)"        "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q grpcroutes"
check "ReferenceGrant served (Lab 7)"   "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q referencegrants"
check "a GatewayClass exists"           "[ -n \"\$(kubectl get gatewayclass -o name 2>/dev/null)\" ]"
check "GatewayClass '${GWC}' Accepted" \
      "[ \"\$(kubectl get gatewayclass ${GWC} -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}')\" = True ]"

cat <<SUMEOF

  Gateway API bundle : ${BUNDLE}
  GatewayClass       : ${GWC}

  Export this for the labs:  export GWCLASS=${GWC}

  Version pairing: Traefik v3.7.x -> Gateway API v1.5, v3.6.x -> v1.4.
  Upstream is ahead. TCPRoute/UDPRoute went GA upstream in v1.6 and are NOT
  in the supported RKE2 path yet.
SUMEOF

summary
