#!/usr/bin/env bash
#
# 40-validate-lab.sh — verify lab outcomes end to end.
#
# Audience : instructor, before delivery. Also useful mid-session to check a
#            participant's cluster without reading over their shoulder.
# Runs on  : anywhere with the lab kubeconfig.
#
#   ./40-validate-lab.sh            # validate every lab that looks set up
#   ./40-validate-lab.sh 4 5 6      # validate specific labs only
#   ./40-validate-lab.sh --answers  # ALSO print the ⚠ VERIFY answers
#
# --answers resolves the open questions in AGENT.md against this cluster:
#   entryPoint names, GatewayClass name, ReferenceGrant served version,
#   whether Ingress annotation weighting works, whether h2c is honoured,
#   and the exact status codes for denied references.
#
if [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
else
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

WANT=()
ANSWERS=no
for a in "$@"; do
  case "$a" in
    --answers) ANSWERS=yes ;;
    [0-9]*)    WANT+=("$a") ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

want() {
  [[ ${#WANT[@]} -eq 0 ]] && return 0
  local n
  for n in "${WANT[@]}"; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}

require_cmd kubectl "Install kubectl."
require_cmd jq "Install jq."
require_kubeconfig
resolve_gw_url

GWC=$(gwclass)

# ---------------------------------------------------------------------------
if want 1; then
title "Lab 1 — bootstrap and plain Ingress"
check "Traefik LB address assigned"     "[ -n \"\$(traefik_lb_addr)\" ]"
check "podinfo-v1 ready"                "[ \"\$(kubectl -n ${DEMO_NS} get deploy podinfo-v1 -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" -ge 1 ]"
check "Ingress 'podinfo' exists"        "kubectl -n ${DEMO_NS} get ingress podinfo"
check "unknown Host is rejected"        "hcode nothing.invalid / | grep -qE '^(404|421|503)'"
soft_check "podinfo.lab serves VERSION ONE" \
      "hcurl podinfo.lab / | jq -e -r '.message' | grep -q 'VERSION ONE'"
soft_check "podinfo.lab/shop is rewritten (Lab 2.1 applied)" \
      "hcurl podinfo.lab /shop/version | jq -e .version"
fi

# ---------------------------------------------------------------------------
if want 2; then
title "Lab 2 — annotations, canary attempt, RBAC problem"
check "Middleware strip-shop exists"    "kubectl -n ${DEMO_NS} get middleware.traefik.io strip-shop"
check "middlewares annotation present" \
      "kubectl -n ${DEMO_NS} get ingress podinfo -o jsonpath='{.metadata.annotations}' | grep -q kubernetescrd"
soft_check "canary Ingress exists"      "kubectl -n ${DEMO_NS} get ingress podinfo-canary"
check "ServiceAccount dev exists"       "kubectl -n ${DEMO_NS} get sa dev"
check "Role ingress-editor exists"      "kubectl -n ${DEMO_NS} get role ingress-editor"
# The whole point of Lab 2.3: this permission SHOULD exist and IS the problem.
check "dev can edit Ingress (the flaw)" \
      "kubectl auth can-i update ingress -n ${DEMO_NS} --as=system:serviceaccount:${DEMO_NS}:dev | grep -q yes"
fi

# ---------------------------------------------------------------------------
if want 3; then
title "Lab 3 — Gateway API enabled"
check "Gateway API CRDs present"        "gateway_api_enabled"
check "HTTPRoute served"                "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q httproutes"
check "GRPCRoute served"                "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q grpcroutes"
check "ReferenceGrant served"           "kubectl api-resources --api-group=gateway.networking.k8s.io | grep -q referencegrants"
check "GatewayClass '${GWC}' Accepted" \
      "[ \"\$(kubectl get gatewayclass ${GWC} -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null)\" = True ]"
check "kubectl explain works on a typed field" \
      "kubectl explain httproute.spec.rules.matches.headers"
fi

# ---------------------------------------------------------------------------
if want 4; then
title "Lab 4 — Gateway + HTTPRoute"
check "Gateway ${INFRA_NS}/web exists"  "kubectl -n ${INFRA_NS} get gateway web"
check "Gateway web is Programmed" \
      "[ \"\$(kubectl -n ${INFRA_NS} get gateway web -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}')\" = True ]"
check "HTTPRoute ${DEMO_NS}/podinfo exists" "kubectl -n ${DEMO_NS} get httproute podinfo"
check "HTTPRoute Accepted"              "[ \"\$(route_condition httproute ${DEMO_NS} podinfo Accepted)\" = True ]"
check "HTTPRoute ResolvedRefs"          "[ \"\$(route_condition httproute ${DEMO_NS} podinfo ResolvedRefs)\" = True ]"
check "gw.podinfo.lab/shop serves podinfo" "hcurl gw.podinfo.lab /shop/version | jq -e .version"
check "typed URLRewrite filter in use" \
      "kubectl -n ${DEMO_NS} get httproute podinfo -o json | jq -e '..|.type?|select(.==\"URLRewrite\")'"
check "Role route-editor exists"        "kubectl -n ${DEMO_NS} get role route-editor"
check "dev CAN edit HTTPRoute" \
      "kubectl auth can-i update httproutes.gateway.networking.k8s.io -n ${DEMO_NS} --as=system:serviceaccount:${DEMO_NS}:dev | grep -q yes"
check "dev CANNOT edit Gateway (the fix)" \
      "kubectl auth can-i update gateways.gateway.networking.k8s.io -n ${INFRA_NS} --as=system:serviceaccount:${DEMO_NS}:dev | grep -q no"
check "dev CANNOT read Secrets in ${INFRA_NS}" \
      "kubectl auth can-i get secrets -n ${INFRA_NS} --as=system:serviceaccount:${DEMO_NS}:dev | grep -q no"
fi

# ---------------------------------------------------------------------------
if want 5; then
title "Lab 5 — weighted canary and header routing"
check "HTTPRoute has weighted backendRefs" \
      "kubectl -n ${DEMO_NS} get httproute podinfo -o json | jq -e '[..|.weight?|select(.!=null)]|length>=2'"
check "header match x-canary present" \
      "kubectl -n ${DEMO_NS} get httproute podinfo -o json | jq -e '..|.name?|select(.==\"x-canary\")'"
check "x-canary: true reaches VERSION TWO" \
      "curl -s -H 'Host: gw.podinfo.lab' -H 'x-canary: true' ${GW_URL}/shop/ | jq -e -r .message | grep -q 'VERSION TWO'"
check "x-served-by response header injected" \
      "curl -si -H 'Host: gw.podinfo.lab' -H 'x-canary: true' ${GW_URL}/shop/ | grep -qi 'x-served-by'"

log "measuring the split over 60 requests (informational)"
for _ in $(seq 1 60); do
  hcurl gw.podinfo.lab /shop/ | jq -r '.message // "ERR"'
done | sort | uniq -c | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 6; then
title "Lab 6 — GRPCRoute"
check "podinfo-grpc ready"              "[ \"\$(kubectl -n ${DEMO_NS} get deploy podinfo-grpc -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" -ge 1 ]"
check "grpc Service declares h2c"       "[ \"\$(kubectl -n ${DEMO_NS} get svc podinfo-grpc -o jsonpath='{.spec.ports[0].appProtocol}')\" = kubernetes.io/h2c ]"
check "GRPCRoute exists"                "kubectl -n ${DEMO_NS} get grpcroute podinfo-grpc"
check "GRPCRoute Accepted"              "[ \"\$(route_condition grpcroute ${DEMO_NS} podinfo-grpc Accepted)\" = True ]"
check "GRPCRoute ResolvedRefs"          "[ \"\$(route_condition grpcroute ${DEMO_NS} podinfo-grpc ResolvedRefs)\" = True ]"
if command -v grpcurl >/dev/null 2>&1; then
  check "grpc health Check routes" \
        "grpcurl -plaintext -authority grpc.podinfo.lab -max-time 10 ${GW_URL#http://} grpc.health.v1.Health/Check"
else
  soft_check "grpc health Check routes (grpcurl absent — use the pod fallback)" "false"
fi
fi

# ---------------------------------------------------------------------------
if want 7; then
title "Lab 7 — multi-tenancy and ReferenceGrant"
check "Gateway ${INFRA_NS}/shared exists" "kubectl -n ${INFRA_NS} get gateway shared"
check "shared Gateway Programmed" \
      "[ \"\$(kubectl -n ${INFRA_NS} get gateway shared -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}')\" = True ]"
check "listener restricts by Selector" \
      "kubectl -n ${INFRA_NS} get gateway shared -o json | jq -e '.spec.listeners[0].allowedRoutes.namespaces.from==\"Selector\"'"
check "listener constrains hostname" \
      "kubectl -n ${INFRA_NS} get gateway shared -o json | jq -e '.spec.listeners[0].hostname|test(\"tenants\")'"
check "${TENANT_A} labelled for access" \
      "kubectl get ns ${TENANT_A} -o jsonpath='{.metadata.labels.gateway-access}' | grep -q true"
check "${TENANT_A} route Accepted"      "[ \"\$(route_condition httproute ${TENANT_A} app Accepted)\" = True ]"
check "${TENANT_A} serves TEAM A"       "hcurl ${TENANT_A}.tenants.lab / | jq -e -r .message | grep -q 'TEAM A'"
soft_check "ReferenceGrant in ${TENANT_B} (Lab 7.6 done)" \
      "kubectl -n ${TENANT_B} get referencegrant allow-team-a"
if kubectl -n "${TENANT_B}" get referencegrant allow-team-a >/dev/null 2>&1; then
  check "${TENANT_A} route ResolvedRefs after grant" \
        "[ \"\$(route_condition httproute ${TENANT_A} app ResolvedRefs)\" = True ]"
fi
fi

# ---------------------------------------------------------------------------
if [[ "$ANSWERS" == yes ]]; then
title "⚠ VERIFY answers for this cluster"
cat <<AEOF

Copy these into AGENT.md and drop the corresponding ⚠ VERIFY markers.

  RKE2 / kubelet        : $(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)
  Traefik image         : $(traefik_image)
  Gateway API bundle    : $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo '(CRDs absent)')
  GatewayClass name     : ${GWC}
  Traefik entryPoints   : $(traefik_entrypoints)
  Traefik LB address    : $(traefik_lb_addr || echo '<none>')
  Data path used here   : ${GW_URL}
  ReferenceGrant vers.  : $(kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null | awk '/referencegrants/{print $3}' | tr '\n' ' ')
  Route kinds served    : $(kubectl api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null | tr '\n' ' ')
AEOF

  echo
  info "Lab 2.2 — does Ingress annotation weighting actually work?"
  if kubectl -n "${DEMO_NS}" get ingress podinfo-canary >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
      hcurl podinfo.lab /shop/ | jq -r '.message // "ERR"'
    done | sort | uniq -c | sed 's/^/      /'
    info "If this is not close to 90/10, annotation weighting does NOT work — that is the lesson."
  else
    info "      (canary Ingress not applied; run Lab 2.2 first)"
  fi

  echo
  info "Lab 6.1 — is appProtocol: kubernetes.io/h2c honoured?"
  if kubectl -n "${DEMO_NS}" get grpcroute podinfo-grpc >/dev/null 2>&1 && command -v grpcurl >/dev/null 2>&1; then
    if grpcurl -plaintext -authority grpc.podinfo.lab -max-time 10 \
         "${GW_URL#http://}" grpc.health.v1.Health/Check 2>&1 | sed 's/^/      /'; then
      info "      -> h2c appears to work."
    else
      info "      -> FAILED. Record the error; this is the Lab 6 open question."
    fi
  else
    info "      (GRPCRoute or grpcurl missing)"
  fi

  echo
  info "Lab 7.5 — status code for a denied cross-namespace backendRef:"
  if [[ "$(route_condition httproute "${TENANT_A}" app ResolvedRefs 2>/dev/null)" == "False" ]]; then
    for _ in $(seq 1 10); do hcode "${TENANT_A}.tenants.lab" /; echo; done | sort | uniq -c | sed 's/^/      /'
  else
    info "      (ResolvedRefs is not False — apply Lab 7.5 without the grant to measure this)"
  fi
fi

summary
