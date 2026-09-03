# Kubernetes Gateway API on RKE2 with Traefik

A half-day (3h30–4h) technical workshop on migrating from the legacy Kubernetes Ingress API to the role-oriented **Kubernetes Gateway API**, delivered on **SUSE RKE2** using the built-in **Traefik** data plane.

---

## 🎯 Workshop Overview

This training guides participants through a hands-on evolution of application routing:
1. **The Ingress Era (2015):** Deploy a baseline web application (**podinfo**), configure host/path routing, live through the *annotation explosion* (URL rewrites, proprietary canary hacks), and expose the single-resource RBAC security flaw.
2. **The Gateway API Era (2026):** Enable Traefik's Gateway provider, split infrastructure and routing concerns into role-oriented resources (`GatewayClass` → `Gateway` → `HTTPRoute`), implement typed rewrites, weighted traffic splitting, header-based canary releases, L7 gRPC routing, and cross-namespace delegation with `ReferenceGrant`.
3. **The Closing Argument:** Run `git diff` on your manifests repository to visually contrast the fragile Ingress annotation stack against standard, typed Gateway API declarations.

---

## 📂 Repository Structure

```text
.
├── 00-check-prereqs.sh             # Prerequisites checker & auto-installer
├── 01-slides-gateway-api-rke2.md   # Unified Marp slide deck & interactive lab guide
├── AGENT.md                        # AI agent & developer guidelines
├── README.md                       # This file
├── common.sh                       # Shared shell helpers & port-forwarding
├── measure-traffic.sh              # Traffic distribution measurement helper
├── ROADMAP-CILIUM-SERVICE-MESH.md  # Technical roadmap & design for Cilium/GAMMA extension
├── deck.html / deck.pdf / deck.pptx# Exported presentation artifacts
└── manifests/                      # 22 core manifests + 7 troubleshooting manifests
    ├── 01-podinfo-v1.yaml            # Lab 1: podinfo v1 Deployment & Service
    ├── 02-ingress.yaml               # Lab 1: Baseline Ingress
    ├── 03-middleware-strip.yaml      # Lab 2.1: Traefik StripPrefix Middleware
    ├── 02-ingress-with-rewrite.yaml  # Lab 2.1: Ingress with Middleware annotation
    ├── 04-podinfo-v2.yaml            # Lab 2.2: podinfo v2 Deployment & Service
    ├── 05-ingress-canary.yaml        # Lab 2.2: IngressRoute canary split
    ├── 06-rbac-ingress.yaml          # Lab 2.4: Flawed Ingress-editor Role
    ├── 08-cleanup-ingress-era.yaml   # Lab 4: Ingress-era cleanup manifest
    ├── 09-helmchartconfig-traefik.yaml # Lab 3: Enable Traefik Gateway Provider
    ├── 10-gateway.yaml               # Lab 4.1: Gateway (port 8000, infra namespace)
    ├── 11-httproute.yaml             # Lab 4.2: Baseline HTTPRoute
    ├── 11-httproute-rewrite-1.yaml   # Lab 4.3a: Isolated URLRewrite (/shop only)
    ├── 11-httproute-rewrite-2.yaml   # Lab 4.3b: Multi-rule coexistence (/shop + /)
    ├── 11-httproute-traffic-split.yaml# Lab 5.1: 90/10 Canary traffic split
    ├── 11-httproute-header-routing.yaml# Lab 5.2: Header routing (X-Canary: always)
    ├── 12-rbac-gateway.yaml          # Lab 4.4: Scoped route-editor Role
    ├── 20-podinfo-grpc.yaml          # Lab 6.1: podinfo gRPC (appProtocol: h2c)
    ├── 21-grpcroute.yaml             # Lab 6.2: GRPCRoute with method matching
    ├── 29-tenants.yaml               # Lab 7.1: team-a & team-b namespaces and apps
    ├── 30-gateway-shared.yaml        # Lab 7.2: Shared Gateway with allowedRoutes
    ├── 30-httproute-team-a.yaml      # Lab 7.3: Tenant HTTPRoute
    ├── 31-referencegrant.yaml        # Lab 7.6: Cross-namespace ReferenceGrant
    ├── 40-gateway-tls.yaml           # App. A: HTTPS Gateway with TLS termination
    ├── 45-gamma-podinfo.yaml         # Reference: GAMMA East-West multi-tier routing
    └── troubleshooting/              # Intentional error triggers for diagnostics
        ├── err-gateway-port-unavailable.yaml
        ├── err-gateway-invalid-certificate.yaml
        ├── err-gateway-listener-conflict.yaml
        ├── err-httproute-not-allowed-by-listeners.yaml
        ├── err-httproute-hostname-mismatch.yaml
        ├── err-httproute-backend-not-found.yaml
        └── err-httproute-ref-not-permitted.yaml
```

---

## 🚀 Quickstart & Setup

### 1. Connect to your Cluster
Set your `KUBECONFIG` pointing to your RKE2 cluster:
```bash
export KUBECONFIG=~/gwapi-lab.kubeconfig
kubectl get nodes
```

### 2. Verify and Install Prerequisites
Run the prerequisite checker. Add `--install-prereqs` to automatically install any missing tools (`kubectl`, `helm`, `grpcurl`, `ingress2gateway`, `gwctl`, `jq`, `git`, `bash-completion`) and configure shell autocompletion:
```bash
./00-check-prereqs.sh --install-prereqs
source ~/.bashrc
```

### 3. Establish Gateway Connectivity (`$GW_URL`)
Traefik listens internally on port `8000` (mapped to port `80` on the node):
* **Option A — Port-Forward (Universal Fallback):**
  ```bash
  kubectl -n kube-system port-forward svc/rke2-traefik 8080:80 &
  export GW_URL="http://127.0.0.1:8080"
  ```
* **Option B — Direct Node / LoadBalancer IP:**
  ```bash
  export GW_URL="http://<NODE_OR_LB_IP>"
  ```

Test connectivity:
```bash
curl -s -o /dev/null -w "%{http_code}\n" "$GW_URL/"   # Expect 404 (Traefik is answering)
```

---

## 🗺️ Lab & Manifests Reference Table

| Lab | Topic & Key Concept | Manifests |
|---|---|---|
| **Lab 1** | **Ingress Baseline:** Bootstrap podinfo v1, configure basic Ingress, verify data plane | `manifests/01-podinfo-v1.yaml`<br>`manifests/02-ingress.yaml` |
| **Lab 2** | **Annotation Explosion:** Path rewrite via Middleware, working 90/10 canary via `IngressRoute`, expose the RBAC delegation security flaw | `manifests/03-middleware-strip.yaml`<br>`manifests/02-ingress-with-rewrite.yaml`<br>`manifests/04-podinfo-v2.yaml`<br>`manifests/05-ingress-canary.yaml`<br>`manifests/06-rbac-ingress.yaml` |
| **Lab 3** | **Enable Gateway API:** Enable Traefik's `kubernetesGateway` provider in RKE2 via `HelmChartConfig`, verify `GatewayClass` | `manifests/09-helmchartconfig-traefik.yaml` |
| **Lab 4** | **Gateway + HTTPRoute Handshake:** Clean legacy Ingress, deploy `Gateway` (`infra`) & `HTTPRoute` (`demo`), observe `NotAllowedByListeners`, open cross-namespace access, typed `URLRewrite`, scoped `route-editor` RBAC | `manifests/08-cleanup-ingress-era.yaml`<br>`manifests/10-gateway.yaml`<br>`manifests/11-httproute.yaml`<br>`manifests/11-httproute-rewrite-1.yaml`<br>`manifests/11-httproute-rewrite-2.yaml`<br>`manifests/12-rbac-gateway.yaml` |
| **Lab 5** | **Expressiveness — Traffic Splitting:** 90/10 canary split in a single `HTTPRoute` without extra objects, deterministic header routing (`X-Canary: always`) | `manifests/11-httproute-traffic-split.yaml`<br>`manifests/11-httproute-header-routing.yaml` |
| **Lab 6** | **Beyond HTTP — GRPCRoute:** Deploy podinfo gRPC backend (`appProtocol: kubernetes.io/h2c`), route methods with `GRPCRoute`, test with `grpcurl` | `manifests/20-podinfo-grpc.yaml`<br>`manifests/21-grpcroute.yaml` |
| **Lab 7** | **Multi-Tenancy & Safe Delegation:** Shared Gateway across tenant namespaces (`team-a`, `team-b`), cross-namespace backend reference rejection (`RefNotPermitted`), authorize with `ReferenceGrant` | `manifests/29-tenants.yaml`<br>`manifests/30-gateway-shared.yaml`<br>`manifests/30-httproute-team-a.yaml`<br>`manifests/31-referencegrant.yaml` |
| **Tooling** | **Gateway API Tools:** Automated migration with `ingress2gateway`, topology inspection with `gwctl` | — |
| **App. A** | **TLS Termination:** HTTPS listener on port `8443` with Secret `certificateRefs` | `manifests/40-gateway-tls.yaml` |

---

## 🔮 Roadmap & Future Extensions

- [x] **Core Gateway API Workshop (North-South with Traefik):** Labs 1–7 covering Ingress migration, URL rewriting, traffic splitting, gRPC, and multi-tenant `ReferenceGrant`.
- [ ] **Cilium Service Mesh on RKE2 (East-West with GAMMA):** Sidecarless eBPF service mesh module covering inter-service routing with `HTTPRoute` (`parentRefs: kind: Service`), fault injection with `podinfo --random-error`, latency timeouts, and Hubble L7 observability.
  * 📋 *See detailed technical specification:* [`ROADMAP-CILIUM-SERVICE-MESH.md`](ROADMAP-CILIUM-SERVICE-MESH.md)

---

## 🖥️ Presentation & Deck Formats

The presentation is built using **[Marp](https://marp.app/)** with SUSE brand styling:
* **Markdown Master:** `01-slides-gateway-api-rke2.md`
* **Interactive HTML:** `deck.html` (Press `P` to toggle speaker notes)
* **PDF Slides:** `deck.pdf`
* **PowerPoint:** `deck.pptx`

To regenerate the slides locally:
```bash
marp --no-stdin 01-slides-gateway-api-rke2.md -o deck.html
marp --no-stdin 01-slides-gateway-api-rke2.md --pdf -o deck.pdf
marp --no-stdin 01-slides-gateway-api-rke2.md --pptx -o deck.pptx
```

---

## 📜 License

Created by **Florian Coulombel** (SUSE Consulting). Licensed under Apache 2.0.
