# Cilium Service Mesh on RKE2 with Gateway API & GAMMA
## Architecture, Podinfo Capabilities & Extension Session Roadmap

This document serves as the technical specification and implementation blueprint for extending the **Kubernetes Gateway API on RKE2** workshop to cover **East-West Service Mesh (GAMMA)** using **Cilium Service Mesh**.

---

## 1. Executive Summary & Context

While **Traefik** serves as the default North-South Ingress/Gateway API data plane in RKE2, modern cloud-native architectures increasingly demand **East-West (service-to-service)** traffic governance, security, and observability inside the cluster.

Traditional service meshes (e.g. Istio sidecar mode, Linkerd) require injecting an Envoy/Linkerd sidecar container into every application pod. **Cilium Service Mesh** leverages **eBPF in the Linux kernel** to provide a **sidecarless service mesh**:
* **Kernel-level interception:** Socket operations (`sockops`) steer traffic directly at the TCP level into a per-node Envoy instance.
* **Standards-based:** Full native adoption of the **Kubernetes Gateway API** and the **GAMMA (Gateway API for Mesh Management and Administration)** specification.
* **Unified API:** The exact same `HTTPRoute` syntax used with Traefik at the edge is used to govern internal microservice calls.

---

## 2. Podinfo Service Mesh Capabilities Investigation

Stefan Prodan’s **`podinfo`** (`ghcr.io/stefanprodan/podinfo`) is the industry-standard microservice simulation workload. It provides first-class support for testing every major service mesh feature without writing custom mock applications.

### 2.1 Capability Matrix

| Capability | Podinfo CLI Flag / Env Var | How it Works | Service Mesh Test Scenario |
|---|---|---|---|
| **Multi-Tier Chaining** | `--backend-url=http://podinfo-backend:9898/echo`<br>`PODINFO_BACKEND_URL` | Calls downstream services and aggregates responses into the JSON payload. | **East-West Chaining:** Frontend calls Backend via Kubernetes DNS, intercepted by Cilium eBPF. |
| **Distributed Tracing** | `--otel-service-name=podinfo-frontend`<br>`PODINFO_OTEL_SERVICE_NAME` | Injects and propagates **W3C Trace Context** (`traceparent`) and **B3 headers** across hops. | **End-to-End Tracing:** Trace requests entering Traefik Gateway, passing through Frontend, and reaching Backend. |
| **Fault Injection** | `--random-error`<br>`PODINFO_RANDOM_ERROR=true` | Injects HTTP 500 Internal Server Error on 1/3 of requests. | **Resilience & Retries:** Test mesh automated retry policies without user-perceived downtime. |
| **Latency / Delay Simulation** | `--random-delay`<br>`--random-delay-min=100ms`<br>`--random-delay-max=1s` | Introduces random latency between specified bounds. | **Timeouts & Circuit Breaking:** Validate `spec.rules[].timeouts.request` in GAMMA `HTTPRoute`. |
| **Targeted Chaos Endpoints** | `GET /delay/{seconds}`<br>`GET /status/{code}`<br>`POST /panic` | Built-in endpoints to immediately induce latency, arbitrary status codes, or container crashes. | **Interactive Debugging:** Induce specific error codes (e.g. 503, 504) to test failover behavior. |
| **Cleartext HTTP/2 & gRPC** | `--h2c`, `--grpc-port=9999`<br>`appProtocol: kubernetes.io/h2c` | Multiplexed binary streaming and gRPC service definitions. | **Multi-Protocol Mesh:** Route gRPC and HTTP/2 cleartext inter-service calls. |
| **Automated Load & Canary CLI** | `podcli check canary ...`<br>`podcli check load ...` | Built-in CLI tool inside the podinfo image for automated load generation. | **Hands-Free Validation:** Continuously generate traffic during canary weight transitions. |

---

## 3. The GAMMA Architecture: North-South vs. East-West

The **GAMMA initiative** (Gateway API for Mesh Management and Administration) standardizes service mesh routing within the core Gateway API project.

```text
                     [ North-South Edge Traffic ]
                                │
                    Host: podinfo.lab (:8000)
                                ▼
         ┌─────────────────────────────────────────────┐
         │         Traefik Gateway (infra/web)         │
         └──────────────────────┬──────────────────────┘
                                │ parentRefs: Gateway/web
                                ▼
         ┌─────────────────────────────────────────────┐
         │            HTTPRoute (podinfo-edge)         │
         └──────────────────────┬──────────────────────┘
                                │
                                ▼
                ┌───────────────────────────────┐
                │   podinfo-frontend (:9898)    │
                └───────────────┬───────────────┘
                                │
                                │ Calls http://podinfo-backend:9898/echo
                                │
                     [ East-West Mesh Traffic ]
                                │
         ┌──────────────────────▼──────────────────────┐
         │     Cilium eBPF Socket Filter (Kernel)      │
         │  Intercepts TCP connect() to Service IP:Port│
         └──────────────────────┬──────────────────────┘
                                │ parentRefs: Service/podinfo-backend
                                ▼
         ┌─────────────────────────────────────────────┐
         │       GAMMA HTTPRoute (podinfo-mesh)        │
         │    (80% weight -> v1, 20% weight -> v2)     │
         └──────────────┬──────────────┬───────────────┘
                        │              │
                        ▼              ▼
         ┌─────────────────────┐ ┌─────────────────────┐
         │ podinfo-backend-v1  │ │ podinfo-backend-v2  │
         │     (Port 9898)     │ │     (Port 9898)     │
         └─────────────────────┘ └─────────────────────┘
```

### The Key Difference: `parentRefs`
* **North-South (Edge / Traefik):**
  `parentRefs` points to a **`kind: Gateway`** resource.
* **East-West (Mesh / Cilium GAMMA):**
  `parentRefs` points directly to a **`kind: Service`** resource.

---

## 4. Proposed Extension Session: Lab Flow Outline

### Lab M.1 — RKE2 Cluster Setup with Cilium Service Mesh
* Configure RKE2 server `/etc/rancher/rke2/config.yaml`:
  ```yaml
  cni: cilium
  ```
* Apply Cilium `HelmChartConfig` to enable L7 Envoy proxy and Gateway API:
  ```yaml
  apiVersion: helm.cattle.io/v1
  kind: HelmChartConfig
  metadata:
    name: rke2-cilium
    namespace: kube-system
  spec:
    valuesContent: |-
      kubeProxyReplacement: true
      gatewayAPI:
        enabled: true
      l7Proxy: true
      hubble:
        enabled: true
        relay:
          enabled: true
        ui:
          enabled: true
  ```

### Lab M.2 — Deploy Two-Tier Microservice Topology
* **Frontend Pod:** Configured with `PODINFO_BACKEND_URL="http://podinfo-backend.demo.svc.cluster.local:9898/echo"`.
* **Backend Deployments:** `podinfo-backend-v1` and `podinfo-backend-v2` behind `Service/podinfo-backend`.
* **Verify baseline:** Querying frontend returns nested JSON containing backend echo responses.

### Lab M.3 — East-West Traffic Splitting via GAMMA HTTPRoute
* Apply GAMMA `HTTPRoute` attached to `Service/podinfo-backend`:
  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: backend-canary
    namespace: demo
  spec:
    parentRefs:
      - group: ""
        kind: Service
        name: podinfo-backend
        port: 9898
    rules:
      - backendRefs:
          - name: podinfo-backend-v1
            port: 9898
            weight: 80
          - name: podinfo-backend-v2
            port: 9898
            weight: 20
  ```
* Run `./measure-traffic.sh` against the frontend endpoint and observe an 80/20 distribution from the backend tiers.

### Lab M.4 — East-West Fault Injection & Automated Retries
* Enable `--random-error` on `podinfo-backend-v2`.
* Observe 500 errors propagating to the frontend.
* Add retry rules or timeout limits to the GAMMA `HTTPRoute`:
  ```yaml
  rules:
    - timeouts:
        request: 250ms
      backendRefs:
        - name: podinfo-backend-v1
          port: 9898
  ```

### Lab M.5 — Hubble eBPF Observability
* Trace pod-to-pod network flows in real-time with Hubble CLI:
  ```bash
  hubble observe --namespace demo --protocol http --follow
  ```
* Inspect HTTP status codes, latency, and TCP drop reasons directly from the kernel.

---

## 5. Deliverables & Implementation Checklist

When scheduled for release, the following assets will be created:

- [ ] **Infrastructure Manifests:**
  - `manifests/mesh/00-rke2-cilium-config.yaml`
  - `manifests/mesh/01-podinfo-two-tier.yaml`
  - `manifests/mesh/02-gamma-traffic-split.yaml`
  - `manifests/mesh/03-gamma-timeouts-retries.yaml`
- [ ] **Slide Deck Extension:**
  - Dedicated slide module: *"Part 6: Sidecarless Service Mesh with Cilium & GAMMA"*.
  - Visual diagrams for eBPF socket redirection (`sockops`) vs sidecar proxies.
- [ ] **Automated Validation:**
  - Pre-flight scripts checking Cilium eBPF status (`cilium status`) and Hubble connectivity.

---

*Document maintained by Florian Coulombel (SUSE Consulting).*
