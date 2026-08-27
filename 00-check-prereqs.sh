#!/usr/bin/env bash
#
# 00-check-prereqs.sh — run this FIRST, from wherever you will drive the lab.
#
# Audience : participant (and instructor, as a smoke test)
# Runs on  : your workstation / jump host
# Needs    : the lab kubeconfig. No SSH, no root, no node access.
#
#   export KUBECONFIG=~/gwapi-lab.kubeconfig
#   ./00-check-prereqs.sh [--install-prereqs]
#
# Verifies local tooling, cluster reachability, RBAC, and that Traefik is
# serving. Exits non-zero if anything required is missing.
#
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INSTALL_PREREQS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-prereqs)
      INSTALL_PREREQS=true
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--install-prereqs]

Options:
  --install-prereqs   Automatically install missing tools (kubectl, grpcurl, git, jq, helm, etc.)
  -h, --help          Show this help message
EOF
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ "$INSTALL_PREREQS" = true ]]; then
  title "Installing prerequisites"

  SUDO=""
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  # 1. Package manager dependencies (git, jq, helm, curl, openssl, tar, gzip, bash-completion)
  if command -v dnf >/dev/null 2>&1; then
    log "Installing system packages via dnf (git, jq, curl, openssl, tar, gzip, bash-completion)..."
    $SUDO dnf install -y git curl openssl tar gzip jq bash-completion 2>/dev/null \
      || $SUDO dnf install -y git curl openssl tar gzip bash-completion 2>/dev/null || warn "dnf install failed"
  elif command -v yum >/dev/null 2>&1; then
    log "Installing system packages via yum (git, jq, curl, openssl, tar, gzip, bash-completion)..."
    $SUDO yum install -y git curl openssl tar gzip jq bash-completion 2>/dev/null \
      || $SUDO yum install -y git curl openssl tar gzip bash-completion 2>/dev/null || warn "yum install failed"
  elif command -v zypper >/dev/null 2>&1; then
    log "Installing system packages via zypper (git, jq, helm, curl, openssl, tar, gzip, bash-completion)..."
    $SUDO zypper --non-interactive install -y git jq helm curl tar gzip openssl bash-completion || warn "zypper install failed"
  elif command -v apt-get >/dev/null 2>&1; then
    log "Installing system packages via apt-get (git, jq, helm, curl, openssl, tar, gzip, bash-completion)..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git jq helm curl tar gzip openssl bash-completion || warn "apt-get install failed"
  fi

  # Fallback for helm if not in OS repos (common on RHEL/CentOS)
  if ! command -v helm >/dev/null 2>&1; then
    log "Installing helm via official script..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash >/dev/null 2>&1 || warn "Could not install helm"
  fi

  # Fallback for jq if EPEL is not enabled on RHEL
  if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq binary..."
    JQ_ARCH="amd64"
    [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && JQ_ARCH="arm64"
    if curl -sSL -o /tmp/jq "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${JQ_ARCH}"; then
      chmod 755 /tmp/jq
      $SUDO install -m 755 /tmp/jq /usr/local/bin/jq 2>/dev/null || $SUDO mv /tmp/jq /usr/local/bin/jq
      rm -f /tmp/jq
    else
      warn "Could not download jq"
    fi
  fi

  # 2. kubectl CLI
  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl..."
    K8S_RELEASE="$(curl -L -s https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")"
    if curl -sSL -o /tmp/kubectl "https://dl.k8s.io/release/${K8S_RELEASE}/bin/linux/amd64/kubectl"; then
      chmod 755 /tmp/kubectl
      $SUDO install -m 755 /tmp/kubectl /usr/local/bin/kubectl 2>/dev/null \
        || $SUDO mv /tmp/kubectl /usr/local/bin/kubectl
      rm -f /tmp/kubectl
    else
      warn "Failed to download kubectl"
    fi
  fi

  # 3. grpcurl
  if ! command -v grpcurl >/dev/null 2>&1; then
    log "Installing grpcurl..."
    GRPCURL_VERSION="${GRPCURL_VERSION:-1.9.3}"
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64|amd64) RPM_ARCH="amd64"; TAR_ARCH="x86_64" ;;
      aarch64|arm64) RPM_ARCH="arm64"; TAR_ARCH="arm64" ;;
      *) RPM_ARCH="amd64"; TAR_ARCH="x86_64" ;;
    esac
    GRPCURL_RPM="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${RPM_ARCH}.rpm"
    if curl -sSL -f -o /tmp/grpcurl.rpm "$GRPCURL_RPM"; then
      if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y --nogpgcheck /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || $SUDO rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || warn "Could not install grpcurl RPM via dnf/rpm"
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y --nogpgcheck /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || $SUDO rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || warn "Could not install grpcurl RPM via yum/rpm"
      elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive --no-gpg-checks install -y --allow-unsigned-rpm /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || $SUDO rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 \
          || warn "Could not install grpcurl RPM via zypper/rpm"
      elif command -v rpm >/dev/null 2>&1; then
        $SUDO rpm -Uvh --force /tmp/grpcurl.rpm >/dev/null 2>&1 || warn "Could not install grpcurl RPM via rpm"
      fi
      rm -f /tmp/grpcurl.rpm
    else
      curl -sSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${TAR_ARCH}.tar.gz" \
        | $SUDO tar -xz -C /usr/local/bin grpcurl 2>/dev/null || warn "Could not extract grpcurl"
    fi
  fi

  # 4. ingress2gateway CLI
  if ! command -v ingress2gateway >/dev/null 2>&1; then
    log "Installing ingress2gateway..."
    I2G_VERSION="${I2G_VERSION:-1.2.0}"
    I2G_ARCH="x86_64"
    [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && I2G_ARCH="arm64"
    I2G_OS="Linux"
    [[ "$(uname -s)" == "Darwin" ]] && I2G_OS="Darwin"
    I2G_URL="https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v${I2G_VERSION}/ingress2gateway_${I2G_OS}_${I2G_ARCH}.tar.gz"
    if curl -sSL -f "$I2G_URL" | $SUDO tar -xz -C /usr/local/bin ingress2gateway 2>/dev/null; then
      $SUDO chmod 755 /usr/local/bin/ingress2gateway
    else
      warn "Could not download ingress2gateway"
    fi
  fi

  # 5. gwctl CLI
  if ! command -v gwctl >/dev/null 2>&1; then
    log "Installing gwctl..."
    GWCTL_VERSION="${GWCTL_VERSION:-0.2.0}"
    GWCTL_ARCH="x86_64"
    [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && GWCTL_ARCH="arm64"
    GWCTL_OS="Linux"
    [[ "$(uname -s)" == "Darwin" ]] && GWCTL_OS="Darwin"
    GWCTL_URL="https://github.com/kubernetes-sigs/gwctl/releases/download/v${GWCTL_VERSION}/gwctl_${GWCTL_OS}_${GWCTL_ARCH}.tar.gz"
    if curl -sSL -f "$GWCTL_URL" | $SUDO tar -xz -C /usr/local/bin gwctl 2>/dev/null; then
      $SUDO chmod 755 /usr/local/bin/gwctl
    else
      warn "Could not download gwctl"
    fi
  fi

  # 6. Kubeconfig setup (if running directly on the RKE2 host)
  if [[ ! -f "$HOME/.kube/config" ]]; then
    if [[ -f /etc/rancher/rke2/rke2.yaml ]] || $SUDO test -f /etc/rancher/rke2/rke2.yaml 2>/dev/null; then
      log "Copying /etc/rancher/rke2/rke2.yaml to ~/.kube/config..."
      mkdir -p "$HOME/.kube"
      $SUDO cp /etc/rancher/rke2/rke2.yaml "$HOME/.kube/config"
      $SUDO chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null || true
      chmod 600 "$HOME/.kube/config"
    fi
  fi

  # 7. Shell autocompletion setup (kubectl, helm, gwctl)
  log "Configuring bash autocompletion (kubectl, helm, gwctl)..."
  if [[ -d /etc/bash_completion.d ]] || $SUDO mkdir -p /etc/bash_completion.d 2>/dev/null; then
    command -v kubectl >/dev/null 2>&1 && kubectl completion bash | $SUDO tee /etc/bash_completion.d/kubectl >/dev/null 2>&1 || true
    command -v helm >/dev/null 2>&1 && helm completion bash | $SUDO tee /etc/bash_completion.d/helm >/dev/null 2>&1 || true
    command -v gwctl >/dev/null 2>&1 && gwctl completion bash | $SUDO tee /etc/bash_completion.d/gwctl >/dev/null 2>&1 || true
  fi

  BASHRC="$HOME/.bashrc"
  if [[ -f "$BASHRC" ]]; then
    grep -q "kubectl completion bash" "$BASHRC" || echo 'command -v kubectl >/dev/null 2>&1 && source <(kubectl completion bash)' >> "$BASHRC"
    grep -q "complete -o default -F __start_kubectl k" "$BASHRC" || echo 'alias k=kubectl && complete -o default -F __start_kubectl k' >> "$BASHRC"
    grep -q "helm completion bash" "$BASHRC" || echo 'command -v helm >/dev/null 2>&1 && source <(helm completion bash)' >> "$BASHRC"
    grep -q "gwctl completion bash" "$BASHRC" || echo 'command -v gwctl >/dev/null 2>&1 && source <(gwctl completion bash)' >> "$BASHRC"
  fi
fi

title "Local tooling"

check "kubectl"                 "command -v kubectl"
check "curl"                    "command -v curl"
check "jq"                      "command -v jq"
check "git (labs track YAML in git)" "command -v git"
soft_check "helm (Lab 1.2 reads podinfo's chart)" "command -v helm"
soft_check "openssl (Appendix A, TLS)"            "command -v openssl"
soft_check "grpcurl (Lab 6; pod fallback exists)" "command -v grpcurl"
soft_check "ingress2gateway (Migration tool)"     "command -v ingress2gateway"
soft_check "gwctl (Gateway API CLI)"             "command -v gwctl"

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

check "Traefik workload present"      "[ -n \"\$(traefik_workload)\" ] && kubectl -n kube-system get \$(traefik_workload) >/dev/null 2>&1"
check "Traefik has ready replicas"    "traefik_ready"
check "Traefik Service present"       "kubectl -n kube-system get svc \$(traefik_service_name) >/dev/null 2>&1"
soft_check "Traefik Service is LoadBalancer" \
      "[ \"\$(kubectl -n kube-system get svc \$(traefik_service_name) -o jsonpath='{.spec.type}' 2>/dev/null)\" = LoadBalancer ]"
soft_check "ServiceLB assigned an address"  "[ -n \"\$(traefik_lb_addr)\" ]"
check "IngressClass 'traefik'"         "kubectl get ingressclass traefik"

info "workload        : $(traefik_workload)"
info "Traefik image   : $(traefik_image)"
SVC_NAME="$(traefik_service_name)"
SVC_TYPE="$(kubectl -n kube-system get svc "$SVC_NAME" -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown)"
info "service         : ${SVC_NAME} (${SVC_TYPE})"
info "Traefik LB addr : $(traefik_lb_addr || echo '<none>')"
info "entryPoints     : $(traefik_entrypoints)"

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
