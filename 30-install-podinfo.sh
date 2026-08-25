#!/usr/bin/env bash
#
# 30-install-podinfo.sh — deploy the lab workload.
#
# Audience : participant (fast path) or instructor (pre-seeding)
# Runs on  : anywhere with the lab kubeconfig.
#
#   ./30-install-podinfo.sh [--with-grpc] [--with-tenants] [--emit-only <dir>]
#
# Labs 1.3 has participants WRITE these manifests by hand into ~/lab and commit
# them to git — that ownership is deliberate and this script does not replace it.
# Use this to pre-seed, to catch up a participant who fell behind, or with
# --emit-only to generate the files they will then own.
#
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WITH_GRPC=no
WITH_TENANTS=no
EMIT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-grpc)    WITH_GRPC=yes; shift ;;
    --with-tenants) WITH_TENANTS=yes; shift ;;
    --emit-only)    EMIT_DIR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$EMIT_DIR" ]]; then
  require_cmd kubectl "Install kubectl."
  require_kubeconfig
fi

IMG="ghcr.io/stefanprodan/podinfo:${PODINFO_TAG}"

# ---------------------------------------------------------------------------
# Manifest generators — one function per lab file, named to match ~/lab/
# ---------------------------------------------------------------------------

gen_01_podinfo_v1() {
cat <<YEOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-v1
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: podinfo, version: v1 }
  template:
    metadata:
      labels: { app: podinfo, version: v1 }
    spec:
      containers:
        - name: podinfo
          image: ${IMG}
          ports:
            - { name: http, containerPort: 9898 }
          env:
            - { name: PODINFO_UI_MESSAGE, value: "VERSION ONE" }
            - { name: PODINFO_UI_COLOR,   value: "#30BA78" }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-v1
  namespace: ${DEMO_NS}
spec:
  selector: { app: podinfo, version: v1 }
  ports:
    - { name: http, port: 9898, targetPort: http }
YEOF
}

gen_04_podinfo_v2() {
cat <<YEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-v2
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: podinfo, version: v2 }
  template:
    metadata:
      labels: { app: podinfo, version: v2 }
    spec:
      containers:
        - name: podinfo
          image: ${IMG}
          ports:
            - { name: http, containerPort: 9898 }
          env:
            - { name: PODINFO_UI_MESSAGE, value: "VERSION TWO" }
            - { name: PODINFO_UI_COLOR,   value: "#FE7C3F" }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-v2
  namespace: ${DEMO_NS}
spec:
  selector: { app: podinfo, version: v2 }
  ports:
    - { name: http, port: 9898, targetPort: http }
YEOF
}

gen_20_podinfo_grpc() {
cat <<YEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-grpc
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: podinfo, proto: grpc }
  template:
    metadata:
      labels: { app: podinfo, proto: grpc }
    spec:
      containers:
        - name: podinfo
          image: ${IMG}
          ports:
            - { name: http, containerPort: 9898 }
            - { name: grpc, containerPort: 9999 }
          env:
            - { name: PODINFO_GRPC_PORT,         value: "9999" }
            - { name: PODINFO_GRPC_SERVICE_NAME, value: "podinfo" }
            - { name: PODINFO_UI_MESSAGE,        value: "GRPC BACKEND" }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-grpc
  namespace: ${DEMO_NS}
spec:
  selector: { app: podinfo, proto: grpc }
  ports:
    - name: grpc
      port: 9999
      targetPort: grpc
      # How Gateway API signals cleartext HTTP/2 to the backend.
      # ⚠ VERIFY Traefik honours this.
      appProtocol: kubernetes.io/h2c
YEOF
}

gen_29_tenants() {
  local t
  for t in "${TENANT_A}" "${TENANT_B}"; do
    local label="${t##*-}"
cat <<YEOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${t}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: ${t}
spec:
  replicas: 1
  selector:
    matchLabels: { app: app }
  template:
    metadata:
      labels: { app: app }
    spec:
      containers:
        - name: podinfo
          image: ${IMG}
          ports:
            - { name: http, containerPort: 9898 }
          env:
            - { name: PODINFO_UI_MESSAGE, value: "TEAM $(echo "$label" | tr '[:lower:]' '[:upper:]')" }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
---
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: ${t}
spec:
  selector: { app: app }
  ports:
    - { name: http, port: 9898, targetPort: http }
---
YEOF
  done
}

# ---------------------------------------------------------------------------
# Emit-only mode: write the files a participant will own, and stop.
# ---------------------------------------------------------------------------
if [[ -n "$EMIT_DIR" ]]; then
  mkdir -p "$EMIT_DIR"
  gen_01_podinfo_v1  > "${EMIT_DIR}/01-podinfo-v1.yaml"
  gen_04_podinfo_v2  > "${EMIT_DIR}/04-podinfo-v2.yaml"
  gen_20_podinfo_grpc> "${EMIT_DIR}/20-podinfo-grpc.yaml"
  gen_29_tenants     > "${EMIT_DIR}/29-tenants.yaml"
  log "wrote manifests to ${EMIT_DIR}"
  ls -1 "${EMIT_DIR}"
  cat <<TIP

Next, as the participant would in Lab 1.4:

  cd ${EMIT_DIR} && git init -q && git add -A \\
    && git commit -qm "Lab 1: podinfo behind a plain Ingress"
TIP
  exit 0
fi

# ---------------------------------------------------------------------------
title "Deploying podinfo"
# ---------------------------------------------------------------------------

log "podinfo v1 (namespace ${DEMO_NS})"
gen_01_podinfo_v1 | kubectl apply -f -

log "podinfo v2 (canary target)"
gen_04_podinfo_v2 | kubectl apply -f -

if [[ "$WITH_GRPC" == yes ]]; then
  log "podinfo gRPC (Lab 6)"
  gen_20_podinfo_grpc | kubectl apply -f -
fi

if [[ "$WITH_TENANTS" == yes ]]; then
  log "tenant namespaces ${TENANT_A} / ${TENANT_B} (Lab 7)"
  gen_29_tenants | kubectl apply -f -
fi

log "waiting for rollouts"
kubectl -n "${DEMO_NS}" rollout status deploy/podinfo-v1 --timeout=3m
kubectl -n "${DEMO_NS}" rollout status deploy/podinfo-v2 --timeout=3m
[[ "$WITH_GRPC" == yes ]] && kubectl -n "${DEMO_NS}" rollout status deploy/podinfo-grpc --timeout=3m
if [[ "$WITH_TENANTS" == yes ]]; then
  kubectl -n "${TENANT_A}" rollout status deploy/app --timeout=3m
  kubectl -n "${TENANT_B}" rollout status deploy/app --timeout=3m
fi

title "Checks"
check "namespace ${DEMO_NS}"        "kubectl get ns ${DEMO_NS}"
check "podinfo-v1 ready"            "[ \"\$(kubectl -n ${DEMO_NS} get deploy podinfo-v1 -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
check "podinfo-v2 ready"            "[ \"\$(kubectl -n ${DEMO_NS} get deploy podinfo-v2 -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
check "Service podinfo-v1 has endpoints" \
      "kubectl -n ${DEMO_NS} get endpoints podinfo-v1 -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q ."
if [[ "$WITH_GRPC" == yes ]]; then
  check "podinfo-grpc ready"        "[ \"\$(kubectl -n ${DEMO_NS} get deploy podinfo-grpc -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
  check "grpc Service has appProtocol h2c" \
        "[ \"\$(kubectl -n ${DEMO_NS} get svc podinfo-grpc -o jsonpath='{.spec.ports[0].appProtocol}')\" = kubernetes.io/h2c ]"
fi
if [[ "$WITH_TENANTS" == yes ]]; then
  check "tenant ${TENANT_A} app ready" "[ \"\$(kubectl -n ${TENANT_A} get deploy app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
  check "tenant ${TENANT_B} app ready" "[ \"\$(kubectl -n ${TENANT_B} get deploy app -o jsonpath='{.status.readyReplicas}')\" -ge 1 ]"
fi

echo
info "No routing exists yet — that is Lab 1.3 (Ingress) and Lab 4 (Gateway API)."
summary
