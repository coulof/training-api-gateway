#!/usr/bin/env bash
#
# 00-check-prereqs.sh — run this FIRST, from wherever you will drive the lab.
#
# Audience : participant (and instructor, as a smoke test)
# Runs on  : your workstation / jump host
# Needs    : the lab kubeconfig. No SSH, no root, no node access.
#
#   export KUBECONFIG=~/gwapi-lab.kubeconfig
#   ./00-check-prereqs.sh
#
# Verifies local tooling, cluster reachability, RBAC, and that Traefik is
# serving. Exits non-zero if anything required is missing.
#
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "Local tooling"

check "kubectl"                 "command -v kubectl"
check "curl"                    "command -v curl"
check "jq"                      "command -v jq"
check "git (labs track YAML in git)" "command -v git"
soft_check "helm (Lab 1.2 reads podinfo's chart)" "command -v helm"
soft_check "openssl (Appendix A, TLS)"            "command -v openssl"
soft_check "grpcurl (Lab 6; pod fallback exists)" "command -v grpcurl"

title "Cluster access"

command -v kubectl >/dev/null 2>&1 \
  || die "kubectl is required and not installed. Fix that, then re-run this script."

require_kubeconfig
info "KUBECONFIG : ${KUBECONFIG:-$HOME/.kube/config}"
info "context    : $(current_context)"

check "cluster reachable"       "kubectl version -o json"
check "can list nodes"          "kubectl get nodes"
check "server version readable" "kubectl version -o json | jq -e .serverVersion"

info "server: $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')"

title "Permissions"
# The labs create namespaces, Gateways, RBAC, and impersonate a ServiceAccount.
# Anything less than cluster-admin will fail partway through, so check up front.

check "create namespaces"       "kubectl auth can-i create namespaces"
check "manage HelmChartConfig (Lab 3)" \
      "kubectl auth can-i create helmchartconfigs.helm.cattle.io -n kube-system"
check "manage RBAC in demo ns (Labs 2.3, 4.5)" \
      "kubectl auth can-i create roles.rbac.authorization.k8s.io -n ${DEMO_NS} --all-namespaces=false || kubectl auth can-i create roles.rbac.authorization.k8s.io"
check "impersonate service accounts (Labs 2.3, 4.5)" \
      "kubectl auth can-i impersonate serviceaccounts"
check "read kube-system services"       "kubectl auth can-i get services -n kube-system"
check "port-forward kube-system services" \
      "kubectl auth can-i create pods/portforward -n kube-system"

title "Ingress data plane"

check "Traefik deployment present"  "kubectl -n kube-system get deploy traefik"
check "Traefik has ready replicas" \
      "[ \"\$(kubectl -n kube-system get deploy traefik -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
check "Traefik Service is LoadBalancer" \
      "[ \"\$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}')\" = LoadBalancer ]"
check "ServiceLB assigned an address"  "[ -n \"\$(traefik_lb_addr)\" ]"
check "IngressClass 'traefik'"         "kubectl get ingressclass traefik"

info "Traefik image   : $(kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"
info "Traefik LB addr : $(traefik_lb_addr || echo '<none>')"
info "entryPoints     : $(kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.name}:{.port} {end}' 2>/dev/null)"

title "Reaching the Gateway from here"

resolve_gw_url
check "something answers on the data path" "hcode nothing.invalid / | grep -qE '^(404|403|421|503)'"

title "Gateway API state"

if gateway_api_enabled; then
  warn "Gateway API CRDs are ALREADY present."
  info "bundle-version: $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo unknown)"
  info "GatewayClass  : $(kubectl get gatewayclass -o name 2>/dev/null | tr '\n' ' ' || echo none)"
  info "Lab 3 becomes an inspection exercise rather than an install. That is fine — say so."
else
  info "Gateway API CRDs absent, as expected. Participants enable them in Lab 3."
fi

summary
