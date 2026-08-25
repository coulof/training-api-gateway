#!/usr/bin/env bash
# common.sh — shared helpers for the Gateway API lab scripts.
# Source this; do not execute it.
#
#   . "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables (override via environment)
# ---------------------------------------------------------------------------
PODINFO_TAG="${PODINFO_TAG:-6.7.0}"
PODINFO_REPO="${PODINFO_REPO:-https://stefanprodan.github.io/podinfo}"
DEMO_NS="${DEMO_NS:-demo}"
INFRA_NS="${INFRA_NS:-infra}"
TENANT_A="${TENANT_A:-team-a}"
TENANT_B="${TENANT_B:-team-b}"
PF_PORT="${PF_PORT:-8080}"
PF_PORT_TLS="${PF_PORT_TLS:-8443}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi

log()   { printf '\n%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()   { printf '\n%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
title() { printf '\n%s%s%s\n%s\n' "$C_B" "$*" "$C_0" "$(printf '%.0s─' $(seq 1 ${#1}))"; }

# ---------------------------------------------------------------------------
# Check accounting — used by the *-check / validate scripts
# ---------------------------------------------------------------------------
CHECKS_RUN=0
CHECKS_FAILED=0

# check "<label>" "<shell expression>"
check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if eval "$2" >/dev/null 2>&1; then
    printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$1"
  else
    printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}

# soft_check — records a warning instead of a failure. For optional tooling.
soft_check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if eval "$2" >/dev/null 2>&1; then
    printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$1"
  else
    printf '  %s[skip]%s %s\n' "$C_Y" "$C_0" "$1"
  fi
}

summary() {
  echo
  if [[ $CHECKS_FAILED -eq 0 ]]; then
    printf '%s%s of %s checks passed.%s\n' "$C_G" "$((CHECKS_RUN - CHECKS_FAILED))" "$CHECKS_RUN" "$C_0"
    return 0
  fi
  printf '%s%s of %s checks FAILED.%s\n' "$C_R" "$CHECKS_FAILED" "$CHECKS_RUN" "$C_0"
  return 1
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. $2"
}

require_kubeconfig() {
  [[ -n "${KUBECONFIG:-}" ]] || [[ -f "$HOME/.kube/config" ]] \
    || die "No KUBECONFIG set and no ~/.kube/config. Export KUBECONFIG to your lab kubeconfig."
  kubectl version -o json >/dev/null 2>&1 \
    || die "Cannot reach the cluster. Check KUBECONFIG=${KUBECONFIG:-~/.kube/config} and network."
}

current_context() { kubectl config current-context 2>/dev/null || echo "(none)"; }

# ---------------------------------------------------------------------------
# Traefik workload and service discovery helpers
# ---------------------------------------------------------------------------

traefik_service_name() {
  if kubectl -n kube-system get svc rke2-traefik >/dev/null 2>&1; then
    echo "rke2-traefik"
  elif kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    echo "traefik"
  else
    local s
    s="$(kubectl -n kube-system get svc -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    echo "${s:-traefik}"
  fi
}

traefik_workload() {
  if kubectl -n kube-system get daemonset rke2-traefik >/dev/null 2>&1; then
    echo "daemonset/rke2-traefik"
  elif kubectl -n kube-system get deploy rke2-traefik >/dev/null 2>&1; then
    echo "deploy/rke2-traefik"
  elif kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
    echo "deploy/traefik"
  elif kubectl -n kube-system get daemonset traefik >/dev/null 2>&1; then
    echo "daemonset/traefik"
  else
    local ds dp
    ds="$(kubectl -n kube-system get daemonset -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$ds" ]]; then
      echo "daemonset/$ds"
      return
    fi
    dp="$(kubectl -n kube-system get deploy -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$dp" ]]; then
      echo "deploy/$dp"
      return
    fi
    echo "deploy/traefik"
  fi
}

traefik_ready() {
  local wl
  wl="$(traefik_workload)"
  local ready=0
  if [[ "$wl" =~ ^daemonset/ ]]; then
    ready="$(kubectl -n kube-system get "$wl" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  else
    ready="$(kubectl -n kube-system get "$wl" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  fi
  [[ "${ready:-0}" -ge 1 ]]
}

traefik_image() {
  local wl
  wl="$(traefik_workload)"
  kubectl -n kube-system get "$wl" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown"
}

traefik_entrypoints() {
  local svc
  svc="$(traefik_service_name)"
  kubectl -n kube-system get svc "$svc" -o jsonpath='{range .spec.ports[*]}{.name}:{.port} {end}' 2>/dev/null || echo "<none>"
}

# Traefik's LoadBalancer address, empty if not assigned.
traefik_lb_addr() {
  local svc
  svc="$(traefik_service_name)"
  kubectl -n kube-system get svc "$svc" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

# resolve_gw_url — sets GW_URL.
#
# Prefers the Traefik LoadBalancer address when it is actually reachable from
# here, because it exercises the real data path. Falls back to a port-forward,
# which works from anywhere a kubeconfig works — including behind a VPN or NAT
# where the node address is not routable.
resolve_gw_url() {
  local addr
  addr="$(traefik_lb_addr)"

  if [[ -n "$addr" ]] && curl -sf -o /dev/null -m 3 "http://${addr}/" 2>/dev/null; then
    GW_URL="http://${addr}"
    info "Gateway reachable directly: $GW_URL"
  elif [[ -n "$addr" ]] && curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${addr}/" 2>/dev/null | grep -q '^[45]'; then
    # A 404 from Traefik is a success for our purposes: something answered.
    GW_URL="http://${addr}"
    info "Gateway reachable directly: $GW_URL"
  else
    [[ -n "$addr" ]] && warn "Traefik LB address ${addr} is not reachable from here; using port-forward."
    start_port_forward
    GW_URL="http://127.0.0.1:${PF_PORT}"
    info "Gateway reachable via port-forward: $GW_URL"
  fi
  export GW_URL
}

PF_PID=""
start_port_forward() {
  local svc
  svc="$(traefik_service_name)"
  kubectl -n kube-system port-forward "svc/${svc}" "${PF_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap stop_port_forward EXIT
  local i
  for i in $(seq 1 20); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:${PF_PORT}/" 2>/dev/null && return 0
    sleep 0.5
  done
  warn "port-forward on ${PF_PORT} did not come up cleanly"
}

stop_port_forward() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  PF_PID=""
}

# hcurl <host> <path> [extra curl args...] — request through the Gateway.
hcurl() {
  local host="$1" path="$2"; shift 2
  curl -s -H "Host: ${host}" "$@" "${GW_URL}${path}"
}

# hcode <host> <path> — HTTP status code only.
hcode() {
  local host="$1" path="$2"
  curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "${GW_URL}${path}"
}

# gwclass — the GatewayClass name this cluster's controller claimed.
gwclass() {
  kubectl get gatewayclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo traefik
}

# route_condition <kind> <ns> <name> <Accepted|ResolvedRefs>
route_condition() {
  kubectl -n "$2" get "$1" "$3" \
    -o jsonpath="{.status.parents[0].conditions[?(@.type=='$4')].status}" 2>/dev/null
}

gateway_api_enabled() {
  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1
}
