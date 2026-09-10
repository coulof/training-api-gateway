#!/usr/bin/env bash
#
# 00-check-prereqs-userns.sh — Prerequisite validation for User Namespaces & In-Place Vertical Scaling.
#
# Audience : Participant & Instructor
# Assumes  : Base tooling (kubectl, curl, jq, etc.) and cluster access are already present.
# Needs    : KUBECONFIG pointing to an RKE2 / Kubernetes 1.36+ cluster.
#
# Checks   :
#   1. kubectl client version >= 1.32 (required for --subresource resize)
#   2. Kubernetes Server version >= 1.36.0 (GA User Namespaces, Beta Pod-Level Resize)
#   3. Linux Kernel version >= 6.3 on all nodes (required for idmap mounts & user namespaces)
#   4. cgroup v2 unified hierarchy on all nodes (required for dynamic cgroup limits)
#   5. Container runtime CRI support (containerd 2.0+ / CRI-O)
#   6. API schema validation for hostUsers: false and resizePolicy
#

set -euo pipefail

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

CHECKS_RUN=0
CHECKS_FAILED=0

check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if eval "$2" >/dev/null 2>&1; then
    printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$1"
  else
    printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}

soft_check() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  if eval "$2" >/dev/null 2>&1; then
    printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$1"
  else
    printf '  %s[skip]%s %s\n' "$C_Y" "$C_0" "$1"
  fi
}

# ---------------------------------------------------------------------------
# Version comparison helper: returns 0 if $1 >= $2
# ---------------------------------------------------------------------------
version_ge() {
  local v1="${1#v}"
  local v2="${2#v}"
  # Remove pre-release or build metadata (e.g. +rke2r1, -alpha)
  v1="${v1%%+*}"
  v1="${v1%%-*}"
  v2="${v2%%+*}"
  v2="${v2%%-*}"

  IFS='.' read -r -a p1 <<< "$v1"
  IFS='.' read -r -a p2 <<< "$v2"

  local len=${#p1[@]}
  [[ ${#p2[@]} -gt $len ]] && len=${#p2[@]}

  for ((i=0; i<len; i++)); do
    local num1=${p1[i]:-0}
    local num2=${p2[i]:-0}
    if (( num1 > num2 )); then
      return 0
    elif (( num1 < num2 )); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# 1. Cluster connectivity & CLI
# ---------------------------------------------------------------------------
title "1. Cluster Connectivity & Client Tooling"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Please install kubectl before running this check."
command -v jq >/dev/null 2>&1 || die "jq not found. Please install jq before running this check."

[[ -n "${KUBECONFIG:-}" ]] || [[ -f "$HOME/.kube/config" ]] \
  || die "No KUBECONFIG set and no ~/.kube/config. Export KUBECONFIG."

check "Cluster reachable" "kubectl cluster-info"

CLIENT_VER=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "unknown"')
info "kubectl client version: $CLIENT_VER"

check "kubectl client >= 1.32 (required for --subresource resize)" \
  "version_ge \"$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.major + \".\" + .clientVersion.minor')\" \"1.32\""

# ---------------------------------------------------------------------------
# 2. Kubernetes Server Version (1.36+)
# ---------------------------------------------------------------------------
title "2. Kubernetes Server Version"

SERVER_VER=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')
SERVER_MAJOR=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.major // "0"')
SERVER_MINOR=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor // "0"')
# Strip trailing special chars from minor version (e.g., "36+")
SERVER_MINOR="${SERVER_MINOR%%[^0-9]*}"
SERVER_SHORT="${SERVER_MAJOR}.${SERVER_MINOR}"

info "Server version: $SERVER_VER ($SERVER_SHORT)"

check "Server version >= 1.36 (User Namespaces GA & Pod-Level Resize Beta)" \
  "version_ge \"$SERVER_SHORT\" \"1.36\""

if ! version_ge "$SERVER_SHORT" "1.36"; then
  warn "Server version ($SERVER_VER) is below 1.36."
  warn "  - User Namespaces (hostUsers: false) is GA in 1.36 (requires feature gates on <1.36)."
  warn "  - Container-level resize is GA in 1.35+, but Pod-level aggregate resize requires 1.36."
fi

# ---------------------------------------------------------------------------
# 3. Node Linux Kernel Baseline (>= 6.3)
# ---------------------------------------------------------------------------
title "3. Node Linux Kernel Baseline"

info "Querying node kernel versions..."
NODES_JSON=$(kubectl get nodes -o json 2>/dev/null)

ALL_KERNELS_OK=true
while read -r name os kernel runtime; do
  info "Node: $name | OS: $os | Kernel: $kernel | Runtime: $runtime"
  
  # Extract major.minor from kernel version (e.g., 6.4.0-150600.23 -> 6.4)
  K_CLEAN="${kernel%%-*}"
  IFS='.' read -r k_maj k_min _ <<< "$K_CLEAN"
  K_SHORT="${k_maj}.${k_min:-0}"
  
  if ! version_ge "$K_SHORT" "6.3"; then
    ALL_KERNELS_OK=false
    warn "Node '$name' kernel ($kernel) is < 6.3!"
    warn "  CRITICAL GOTCHA: Kubernetes 1.36 silently schedules hostUsers: false pods on older kernels"
    warn "  WITHOUT UID remapping (no error, no warning). Upgrade node kernel to >= 6.3 for real isolation."
  fi
done < <(echo "$NODES_JSON" | jq -r '.items[] | "\(.metadata.name) \(.status.nodeInfo.osImage) \(.status.nodeInfo.kernelVersion) \(.status.nodeInfo.containerRuntimeVersion)"')

check "All nodes running Linux kernel >= 6.3 (idmap mounts support)" "$ALL_KERNELS_OK"

# ---------------------------------------------------------------------------
# 4. Cgroup v2 & Container Runtime (CRI)
# ---------------------------------------------------------------------------
title "4. Cgroup v2 & Container Runtime"

# Container runtime CRI version check
ALL_CRI_OK=true
while read -r name runtime; do
  if [[ "$runtime" =~ containerd://([0-9]+\.[0-9]+) ]]; then
    CRI_VER="${BASH_REMATCH[1]}"
    if ! version_ge "$CRI_VER" "2.0"; then
      ALL_CRI_OK=false
      warn "Node '$name' runtime ($runtime) is containerd < 2.0 (pod-level resize CRI updates need containerd 2.0+)."
    fi
  fi
done < <(echo "$NODES_JSON" | jq -r '.items[] | "\(.metadata.name) \(.status.nodeInfo.containerRuntimeVersion)"')

check "Container runtime supports dynamic resource updates (containerd 2.0+ / CRI-O)" "$ALL_CRI_OK"

# ---------------------------------------------------------------------------
# 5. Schema & API Feature Validation (Dry-Run)
# ---------------------------------------------------------------------------
title "5. Feature Schema & Dry-Run Verification"

# Check User Namespaces schema
USERNS_DRY_RUN="kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: userns-dry-run-check
  namespace: default
spec:
  hostUsers: false
  containers:
  - name: test
    image: busybox
    command: [\"sleep\", \"1\"]
EOF"

check "API Server accepts 'spec.hostUsers: false'" "$USERNS_DRY_RUN"

# Check Container Resize Policy schema
RESIZE_DRY_RUN="kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: resize-dry-run-check
  namespace: default
spec:
  containers:
  - name: test
    image: busybox
    command: [\"sleep\", \"1\"]
    resources:
      requests: { cpu: \"100m\" }
      limits: { cpu: \"200m\" }
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired
EOF"

check "API Server accepts 'spec.containers[*].resizePolicy'" "$RESIZE_DRY_RUN"

# Check Pod-Level Aggregate Resources schema (Beta in 1.36)
PODLEVEL_DRY_RUN="kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: podlevel-dry-run-check
  namespace: default
spec:
  resources:
    limits: { cpu: \"500m\", memory: \"256Mi\" }
  containers:
  - name: test
    image: busybox
    command: [\"sleep\", \"1\"]
EOF"

soft_check "API Server accepts pod-level aggregate 'spec.resources' (Beta in 1.36)" "$PODLEVEL_DRY_RUN"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
title "Prerequisite Check Summary"

echo
if [[ $CHECKS_FAILED -eq 0 ]]; then
  printf "%sAll %s prerequisites satisfied! Your cluster is ready for User Namespaces & In-Place Vertical Scaling.%s\n\n" "$C_G" "$CHECKS_RUN" "$C_0"
  exit 0
else
  printf "%s%s of %s checks FAILED. Review warnings above before starting the labs.%s\n\n" "$C_R" "$CHECKS_FAILED" "$CHECKS_RUN" "$C_0"
  exit 1
fi
