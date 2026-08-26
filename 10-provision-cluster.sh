#!/usr/bin/env bash
#
# 10-provision-cluster.sh — build one RKE2 lab cluster and emit a kubeconfig.
#
# Audience : INSTRUCTOR ONLY
# Runs on  : the lab VM, as root, over SSH
# Emits    : /root/gwapi-lab.kubeconfig  (hand this to the participant)
#
# This is the only script that needs node access. Everything after it runs
# through the kubeconfig this produces.
#
#   ./10-provision-cluster.sh [--advertise <ip-or-dns>]
#
# --advertise  address participants will use to reach the API server.
#              Defaults to the node's internal IP. Set this to the public IP
#              or DNS name if participants connect from outside the subnet.
#
set -euo pipefail

RKE2_CHANNEL="${RKE2_CHANNEL:-stable}"
RKE2_VERSION="${RKE2_VERSION:-}"       # optional pin, e.g. v1.35.4+rke2r1
ADVERTISE=""
OUT_KUBECONFIG="${OUT_KUBECONFIG:-/root/gwapi-lab.kubeconfig}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --advertise) ADVERTISE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RKE2_BIN=/var/lib/rancher/rke2/bin
CTR_SOCK=/run/k3s/containerd/containerd.sock

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root on the lab VM."

# ---------------------------------------------------------------------------
log "OS prerequisites & tooling"
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) RPM_ARCH="amd64" ;;
  aarch64|arm64) RPM_ARCH="arm64" ;;
  *) RPM_ARCH="amd64" ;;
esac
GRPCURL_VERSION="${GRPCURL_VERSION:-1.9.3}"
GRPCURL_RPM="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${RPM_ARCH}.rpm"

if command -v dnf >/dev/null 2>&1; then
  dnf install -y git curl openssl tar gzip jq >/dev/null 2>&1 || dnf install -y git curl openssl tar gzip >/dev/null 2>&1
  if curl -sSL -f -o /tmp/grpcurl.rpm "$GRPCURL_RPM"; then
    dnf install -y --nogpgcheck /tmp/grpcurl.rpm >/dev/null 2>&1 || rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 || warn "Could not install grpcurl RPM"
    rm -f /tmp/grpcurl.rpm
  fi
elif command -v yum >/dev/null 2>&1; then
  yum install -y git curl openssl tar gzip jq >/dev/null 2>&1 || yum install -y git curl openssl tar gzip >/dev/null 2>&1
  if curl -sSL -f -o /tmp/grpcurl.rpm "$GRPCURL_RPM"; then
    yum install -y --nogpgcheck /tmp/grpcurl.rpm >/dev/null 2>&1 || rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 || warn "Could not install grpcurl RPM"
    rm -f /tmp/grpcurl.rpm
  fi
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive install -y curl jq git helm tar gzip openssl >/dev/null
  if curl -sSL -f -o /tmp/grpcurl.rpm "$GRPCURL_RPM"; then
    zypper --non-interactive --no-gpg-checks install -y --allow-unsigned-rpm /tmp/grpcurl.rpm >/dev/null 2>&1 \
      || rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 \
      || warn "Could not install grpcurl RPM"
    rm -f /tmp/grpcurl.rpm
  fi
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl jq git helm tar gzip openssl >/dev/null
else
  warn "Unknown package manager — ensure curl, jq, git, helm, tar, openssl are present."
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1 || warn "Could not install helm"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  K8S_RELEASE="$(curl -L -s https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")"
  curl -sSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${K8S_RELEASE}/bin/linux/amd64/kubectl" && chmod 755 /usr/local/bin/kubectl || warn "Could not install kubectl"
fi

if systemctl is-enabled firewalld >/dev/null 2>&1; then
  log "disabling firewalld (RKE2 recommendation; disposable lab VM)"
  systemctl disable --now firewalld
fi

if systemctl is-active NetworkManager >/dev/null 2>&1; then
  install -d /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*;interface-name:cni*;interface-name:veth*
NMEOF
  systemctl reload NetworkManager || true
fi

# ---------------------------------------------------------------------------
log "RKE2 server — Traefik ingress + ServiceLB"
# ---------------------------------------------------------------------------
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[[ -n "$NODE_IP" ]] || die "Could not determine the node IP."
[[ -n "$ADVERTISE" ]] || ADVERTISE="$NODE_IP"

if systemctl is-active rke2-server >/dev/null 2>&1; then
  log "rke2-server already running — skipping install"
else
  install -d /etc/rancher/rke2
  # ingress-controller: traefik -> the SUSE-supported Gateway API path
  # enable-servicelb        -> LoadBalancer Services get the node address
  # tls-san                 -> so the emitted kubeconfig's server name validates
  # Gateway API is deliberately NOT enabled here; that is Lab 3.
  cat > /etc/rancher/rke2/config.yaml <<CFGEOF
write-kubeconfig-mode: "0644"
ingress-controller: traefik
enable-servicelb: true
tls-san:
  - ${ADVERTISE}
  - ${NODE_IP}
  - $(hostname -f 2>/dev/null || hostname)
CFGEOF

  if [[ -n "$RKE2_VERSION" ]]; then
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" sh -
  else
    curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="${RKE2_CHANNEL}" sh -
  fi
  systemctl enable --now rke2-server.service
fi

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:$RKE2_BIN

log "waiting for node Ready (up to 10 min)"
for i in $(seq 1 120); do
  kubectl get nodes 2>/dev/null | grep -qw Ready && break
  sleep 5
  [[ $i -eq 120 ]] && die "Node never became Ready. journalctl -u rke2-server -n 100"
done
kubectl get nodes

log "waiting for Traefik"
for i in $(seq 1 60); do
  kubectl -n kube-system get deploy traefik >/dev/null 2>&1 && break
  sleep 5
  [[ $i -eq 60 ]] && die "Traefik never appeared. Does this RKE2 version support 'ingress-controller: traefik'?"
done
kubectl -n kube-system rollout status deploy/traefik --timeout=5m \
  || warn "Traefik not ready yet — re-check before the session"

log "waiting for ServiceLB to assign an address"
for i in $(seq 1 30); do
  [[ -n "$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]] && break
  sleep 5
  [[ $i -eq 30 ]] && warn "Traefik Service still has no external address — check klipper-lb"
done

# ---------------------------------------------------------------------------
log "pre-pulling lab images"
# ---------------------------------------------------------------------------
for img in \
  "ghcr.io/stefanprodan/podinfo:${PODINFO_TAG:-6.7.0}" \
  "docker.io/fullstorydev/grpcurl:latest" ; do
  printf '    pulling %s\n' "$img"
  "$RKE2_BIN/ctr" -a "$CTR_SOCK" -n k8s.io images pull "$img" >/dev/null 2>&1 \
    || warn "could not pre-pull $img"
done

# ---------------------------------------------------------------------------
log "emitting participant kubeconfig"
# ---------------------------------------------------------------------------
# The in-cluster kubeconfig points at 127.0.0.1. Rewrite it for remote use.
sed "s#https://127.0.0.1:6443#https://${ADVERTISE}:6443#" \
  /etc/rancher/rke2/rke2.yaml > "$OUT_KUBECONFIG"

"$RKE2_BIN/kubectl" --kubeconfig "$OUT_KUBECONFIG" config rename-context default gwapi-lab >/dev/null 2>&1 || true
chmod 600 "$OUT_KUBECONFIG"

KUBECONFIG="$OUT_KUBECONFIG" kubectl get nodes >/dev/null 2>&1 \
  || warn "The emitted kubeconfig could not reach the API server via ${ADVERTISE}:6443.
          Re-run with --advertise <reachable-address>, or check firewall rules on 6443."

cat <<SUMEOF

$(printf '\033[1;32m')Cluster ready.$(printf '\033[0m')

  Node IP          : ${NODE_IP}
  Advertised as    : ${ADVERTISE}
  API server       : https://${ADVERTISE}:6443
  Traefik LB addr  : $(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<none>')
  Kubeconfig       : ${OUT_KUBECONFIG}

Hand ${OUT_KUBECONFIG} to the participant. They then run, from their own machine:

  export KUBECONFIG=./gwapi-lab.kubeconfig
  ./00-check-prereqs.sh
  ./30-install-podinfo.sh        # or do it by hand as Lab 1.3

$(printf '\033[1;33m')This kubeconfig is cluster-admin.$(printf '\033[0m') The labs create namespaces, RBAC, and
impersonate service accounts, so a scoped credential will fail partway through.
Treat these clusters as disposable and destroy them after the session.
SUMEOF
