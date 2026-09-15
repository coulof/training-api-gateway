# Kubernetes Gateway API: Dedicated IPs, Layer 4 TCP Routing & Controller Feature Matrix

**Audience:** Platform Engineers, SREs, Kubernetes Architects  
**Context:** Kubernetes Gateway API v1.6.1 / SUSE RKE2 / Traefik vs. Cilium

---

## 1. The Core Question: Can We Have Dedicated IPs Per Service?

A common requirement when designing Kubernetes ingress and service networking is:  
> *"Can I assign a dedicated external IP address to a specific backend service instead of sharing a single cluster-wide IP?"*

The short answer is **YES**, but the mechanism depends on whether your workload is **Layer 7 (HTTP/gRPC)** or **Layer 4 (raw TCP/UDP)**, and whether your Gateway controller uses **Static** or **Dynamic** infrastructure.

---

## 2. Layer 7 vs. Layer 4 Routing Mechanics

### Layer 7 (HTTP, HTTPS, gRPC): Shared IPs by Design
In HTTP and gRPC, hundreds of services routinely share a single IP address and standard ports (`80` / `443`):
* **HTTP:** Multiplexed via the `Host` request header (`Host: api.example.com` vs. `Host: web.example.com`).
* **HTTPS:** Multiplexed via TLS **SNI (Server Name Indication)** during the handshake.

```text
[ Client ] ──► curl -H "Host: billing.acme.com" http://198.51.100.10/ ──► [ HTTPRoute Billing ] ──► Billing Pods
[ Client ] ──► curl -H "Host: auth.acme.com"    http://198.51.100.10/ ──► [ HTTPRoute Auth ]    ──► Auth Pods
```
*Dedicated IPs for L7 are typically unnecessary unless required for strict tenant compliance or legacy non-SNI clients.*

---

### Layer 4 (TCP & UDP): The Port Collision Dilemma
Non-HTTP workloads (Redis, PostgreSQL, MySQL, MQTT, Kafka) communicate over **raw byte streams or datagrams**.
* **There is NO application-level `Host` header.**
* The proxy only sees the transport tuple: `Source IP:Port ➔ Destination IP:Port`.

If you run **Redis-A** (port `6379`) and **Redis-B** (port `6379`):
**They CANNOT share the same IP:Port combination.**

To route external traffic to both services, you have two architectural choices:
1. **Port Multiplexing (Single IP, Different Ports):**
   * `198.51.100.10:6379` ➔ Routes via `TCPRoute A` to Redis-A
   * `198.51.100.10:6380` ➔ Routes via `TCPRoute B` to Redis-B
2. **Dedicated IPs (Multiple IPs, Same Port):**
   * `198.51.100.10:6379` ➔ Routes via Gateway A to Redis-A
   * `198.51.100.20:6379` ➔ Routes via Gateway B to Redis-B

---

## 3. How Gateway API Models Dedicated IPs (`spec.addresses`)

In the Kubernetes Gateway API specification, **IP addresses belong to the `Gateway` resource**, NOT to the routes (`HTTPRoute`, `TCPRoute`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: dedicated-gateway-redis-a
  namespace: infra
spec:
  gatewayClassName: cilium # or envoy-gateway, etc.
  addresses:
    - type: IPAddress
      value: "198.51.100.10"       # Dedicated IP for Workload A
  listeners:
    - name: redis
      port: 6379
      protocol: TCP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: dedicated-gateway-redis-b
  namespace: infra
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: "198.51.100.20"       # Dedicated IP for Workload B
  listeners:
    - name: redis
      port: 6379
      protocol: TCP
```

---

## 4. Architectural Divide: Static vs. Dynamic Infrastructure

| Model | Implementations | Provisioning Behavior | Dedicated IP Feasibility |
|---|---|---|---|
| **Dynamic Controllers** | **Cilium**, **Envoy Gateway**, NGINX Gateway Fabric | Creating a `Gateway` resource automatically spins up a dedicated proxy or `LoadBalancer` Service via Cloud Controller / MetalLB. | **Native 1:1.** Each `Gateway` can request its own dedicated external IP automatically. |
| **Static Controllers** | **Traefik on RKE2/K3s** | Traefik is pre-deployed as a single DaemonSet/Deployment listening on `0.0.0.0`. Gateways bind to existing Traefik entryPoints. | **Shared by default.** Requires multi-instance Helm deployments or secondary host IPs to achieve separate external IPs. |

---

## 5. Feature Maturity Comparison: Traefik vs. Cilium

Both **Traefik** (default in RKE2 v1.36+) and **Cilium** (eBPF Service Mesh) support Gateway API v1.6.1, but their protocol support and data planes diverge significantly:

| Gateway API Feature | Upstream Status | Traefik Proxy (v3.7.x / current RKE2) | Cilium Service Mesh (v1.20+) |
|---|---|---|---|
| **`HTTPRoute`** | **GA (v1)** | ✅ Fully supported (Core + Extended filters) | ✅ Fully supported (Core + Extended filters) |
| **`GRPCRoute`** | **GA (v1)** | ✅ Fully supported (Method matching, h2c) | ✅ Fully supported (Envoy-backed) |
| **`TLSRoute` (SNI)** | **GA (v1)** | ✅ Supported (`v1alpha2` in v3.7; `v1` in v3.8) | ✅ Fully supported (`v1` Standard) |
| **`TCPRoute` (L4)** | **GA (v1 in 1.6)** | ⚠️ **Experimental only** (`v1alpha2`, needs `experimentalChannel: true`; `v1` GA in v3.8 via [PR #13626](https://github.com/traefik/traefik/pull/13626)) | ✅ **GA (`v1`)** (eBPF Maglev/LB bypasses Envoy via [PR #46184](https://github.com/cilium/cilium/pull/46184) & [PR #46970](https://github.com/cilium/cilium/pull/46970)) |
| **`UDPRoute` (L4)** | **GA (v1 in 1.6)** | ❌ Not yet supported (Open [Issue #12322](https://github.com/traefik/traefik/issues/12322) / [PR #12472](https://github.com/traefik/traefik/pull/12472)) | ✅ **GA (`v1`)** (eBPF Service LoadBalancer) |
| **`BackendTLSPolicy`** | **Standard (v1alpha3)** | ✅ Supported | ✅ Supported |
| **`ReferenceGrant`** | **Standard (v1beta1)** | ✅ Supported (cross-namespace safety) | ✅ Supported |
| **East-West (GAMMA)** | **Standard** | ❌ **No** (North-South Edge only; Traefik Mesh is archived/EOL) | ✅ **Yes** (`parentRefs: kind: Service`, sidecarless eBPF routing) |
| **Data Plane Architecture** | — | User-space Go reverse proxy (Traefik process) | **Hybrid:** Envoy for L7 (HTTP/gRPC), pure **eBPF kernel bypass** for L4 (TCP/UDP) |
| **Multi-IP Allocation** | — | Single shared ServiceLB address by default | Native IPAM (LB-IPAM, BGP, MetalLB integration) |

---

## 6. Recommendations for Architecture & SOWs

1. **When using Traefik on RKE2 (The Standard Path):**
   * **For Web & Microservices (L7):** Best-in-class, minimal resource footprint, single static DaemonSet. Multiplex all services via `HTTPRoute` and `GRPCRoute` on shared ports 80/443.
   * **For TCP Services:** Use **Port Multiplexing** (e.g. Redis on 6379, Postgres on 5432, secondary Redis on 6380) under the same Gateway. Ensure the `rke2-traefik` HelmChartConfig exposes the target ports and enables `experimentalChannel: true` until Traefik v3.8 lands.
2. **When to Choose Cilium Service Mesh (The Advanced eBPF Path):**
   * When workloads require **true dedicated IPs per service/gateway** via BGP or LB-IPAM.
   * When high-throughput **raw TCP/UDP** is required (Cilium bypasses Envoy and proxies L4 directly in the eBPF kernel).
   * When you need unified **East-West Service Mesh (GAMMA)** where pods route internally using the same `HTTPRoute` specs without sidecar proxies.
