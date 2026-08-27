---
marp: true
theme: default
paginate: true
size: 16:9
title: "Kubernetes Gateway API on RKE2"
author: "Florian Coulombel — SUSE Consulting"
style: |
  :root {
    --suse-jungle:    #0C322C;
    --suse-green:     #30BA78;
    --suse-mint:      #90EBCD;
    --suse-waterhole: #2453FF;
    --suse-persimmon: #FE7C3F;
    --suse-grey:      #6E6E6E;
  }
  section {
    background: #FFFFFF;
    color: var(--suse-jungle);
    font-family: "Poppins", "Inter", "Helvetica Neue", Arial, sans-serif;
    font-size: 25px;
    padding: 50px 65px;
  }
  section h1 {
    color: var(--suse-jungle);
    font-size: 1.50em;
    border-bottom: 4px solid var(--suse-green);
    padding-bottom: 10px;
    margin-bottom: 20px;
  }
  section h2 { color: var(--suse-green); font-size: 1.15em; }
  section h3 { color: var(--suse-jungle); font-size: 0.95em; }
  section code { font-size: 0.82em; background: #F2F7F5; }
  section pre { font-size: 0.64em; line-height: 1.32; background: #F2F7F5;
                border-left: 5px solid var(--suse-green); padding: 12px 16px; margin: 12px 0; }
  section table { font-size: 0.78em; }
  section th { background: var(--suse-jungle); color: #FFFFFF; }
  section strong { color: var(--suse-green); }
  section a { color: var(--suse-waterhole); }
  section.lead {
    background: var(--suse-jungle); color: #FFFFFF;
    display: flex; flex-direction: column; justify-content: center;
  }
  section.lead h1 { color: #FFFFFF; border-bottom: 4px solid var(--suse-green); }
  section.lead h2 { color: var(--suse-mint); }
  section.lead strong { color: var(--suse-mint); }
  section.divider {
    background: var(--suse-green); color: var(--suse-jungle);
    display: flex; flex-direction: column; justify-content: center;
  }
  section.divider h1 { color: var(--suse-jungle); border-bottom: none; font-size: 2.2em; }
  section.divider h2 { color: var(--suse-jungle); font-weight: 400; }
  section.lab { border-left: 22px solid var(--suse-persimmon); }
  section.lab h1 { border-bottom: 4px solid var(--suse-persimmon); }
  .small { font-size: 0.78em; color: var(--suse-grey); }
  .warn  { color: var(--suse-persimmon); font-weight: 600; }
  footer { color: var(--suse-grey); font-size: 0.55em; }
footer: "Gateway API on RKE2 — SUSE Consulting"
---

<!-- _class: lead -->
<!-- _paginate: false -->

# Kubernetes Gateway API

## From Ingress to role-oriented service networking — on Rancher & RKE2

**Half-day workshop**
Florian Coulombel — SUSE Consulting

<!--
Presenter notes throughout this deck are in HTML comments.
Timing target: theory 0:00–0:55, labs 1:00–3:20, wrap 3:20–3:40.
Ask up front: who runs Ingress in prod today? who has already touched Gateway API?
Adjust depth of Part 1 accordingly — if the room is senior, compress History to ~12 min.
-->

---

# How today works

**Concept, then immediately prove it on your own cluster.**

| | Block | Labs | Focus |
|---|---|---|---|
| 1 | Ingress: what it gave us, what it cost | **1–2** | Baseline Ingress & annotation pain |
| 2 | Why Gateway API — the resource model | **3–4** | Enable in RKE2 & HTTPRoute routing |
| — | *Break* | | |
| 3 | Expressiveness: canary, headers, gRPC | **5–6** | Weighted splitting & GRPCRoute |
| 4 | Multi-tenancy and safe references | **7** | Shared Gateway & ReferenceGrant |
| 5 | RKE2 reality, migration strategy, wrap | — | Production architecture & git diff |

Every lab has ready-to-use manifests in `manifests/`. We configure **podinfo** first the Ingress way, then the Gateway API way, tracked in git.

---

<!-- _class: lab -->

# Your environment

- One **single-node RKE2** cluster each, driven **entirely from a kubeconfig**
- No SSH. No root. No node access. Everything is `kubectl`.
- Ingress data plane: **Traefik** (DaemonSet/Deployment)
- Workload: **podinfo** (v1, v2, gRPC)

```bash
export KUBECONFIG=./gwapi-lab.kubeconfig
./scripts/00-check-prereqs.sh          # verify tooling, RBAC, Traefik, data path

# Gateway URL: port-forward fallback works from anywhere a kubeconfig works
kubectl -n kube-system port-forward svc/rke2-traefik 8080:80 &
export GW_URL="http://127.0.0.1:8080"
```

<span class="small">If Traefik's LoadBalancer address is routable from your machine, use that instead (`export GW_URL="http://<LB_IP>"`).</span>

---

# Meet the workload: podinfo

A lightweight Go microservice by Stefan Prodan ([github.com/stefanprodan/podinfo](https://github.com/stefanprodan/podinfo)) designed for Kubernetes testing.

- **Dual-Engine Architecture:**
  - **HTTP/1.1 REST Server (`:9898`)**: Handles web UI, API routing, and header echo
  - **gRPC Server (`:9999`)**: Implements standard `grpc.health.v1.Health`
- **Dynamic Configuration via Environment Variables:**
  - `PODINFO_UI_MESSAGE`: Custom payload string (`VERSION ONE`, `VERSION TWO`, `TEAM A`)
  - `PODINFO_UI_COLOR`: Color theme (`#30BA78` green, `#FE7C3F` orange, `#2453FF` blue)
  - `PODINFO_GRPC_PORT`: Enables the internal gRPC listener on port `9999`
- **Zero Application Bugs:** Eliminates test ambiguity — when `curl` returns a payload, you know immediately which backend, version, and headers were matched.

---

# How we use podinfo in the demos

| Component & Endpoint | Demo Feature | Used In |
|---|---|---|
| `GET /` + `PODINFO_UI_MESSAGE` | **Canary weights & Multi-tenancy** (90/10 split, tenant routing) | Labs 1, 4, 5, 7 |
| `GET /shop` + subpaths | **URL Path Rewrites** (`/shop/version` → `/version`) | Labs 2, 4 |
| `GET /headers` | **Header Matching & Modifiers** (`X-Canary`, header injection) | Labs 4, 5 |
| gRPC `:9999` (`Health/Check`) | **L7 GRPCRoute** with cleartext HTTP/2 (`h2c`) | Lab 6 |
| `GET /readyz` | **Kubernetes Probes & Status condition handshake** | All Labs |

<!--
Presenter note:
Highlight that we deploy 4 distinct flavors of podinfo (v1 green, v2 orange, grpc, and tenant apps)
to prove every dimension of the Gateway API specification.
-->

---

<!-- _class: divider -->

# Part 1

## History: The Ingress Era

---

# 2015 — Ingress is born

- Introduced in **Kubernetes 1.1** (November 2015) as `extensions/v1beta1`
- Goal: a portable way to expose HTTP services without a cloud-specific LoadBalancer per app
- Deliberately **minimal**: host + path → Service
- Design assumption: *"the interesting bits are vendor-specific anyway"*

**That assumption is the origin of every problem we are about to discuss.**

<!--
Key framing for the whole session: Ingress was not badly designed. It was
*narrowly* designed for 2015's problem — get HTTP traffic into a cluster.
Everything since has been the ecosystem paying interest on that decision.
-->

---

# What Ingress gave us

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: podinfo
spec:
  ingressClassName: traefik
  rules:
    - host: podinfo.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: podinfo-v1
                port:
                  number: 9898
```

Genuinely useful. Genuinely portable. **For exactly this.**

---

<!-- _class: lab -->

# Lab 1.1 & 1.2 — Setup & Inspect

**Goal:** Verify cluster ingress and explore the workload manifests.

1. **Verify Traefik ingress data plane:**
   ```bash
   kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik
   kubectl get ingressclass traefik
   ```
2. **Prepare your lab git repository:**
   ```bash
   mkdir -p ~/lab && cd ~/lab
   git init -q
   ```
3. **Inspect the pre-built manifests:**
   - `manifests/01-podinfo-v1.yaml`: Namespace `demo`, Deployment `podinfo-v1`, Service `podinfo-v1:9898`
   - `manifests/02-ingress.yaml`: Ingress `podinfo` (host: `podinfo.lab`)

---

<!-- _class: lab -->

# Lab 1.3 & 1.4 — Deploy & Verify Ingress

**Goal:** Deploy podinfo v1 and verify baseline HTTP routing through Ingress.

1. **Deploy podinfo v1 and the baseline Ingress:**
   ```bash
   kubectl apply -f manifests/01-podinfo-v1.yaml
   kubectl apply -f manifests/02-ingress.yaml
   ```
2. **Verify traffic routing:**
   ```bash
   curl -s -H 'Host: podinfo.lab' "$GW_URL/" | jq .
   ```
   *Expected response:*
   ```json
   { "message": "VERSION ONE", "color": "#30BA78", "version": "6.7.0" }
   ```
3. **Save and commit:**
   ```bash
   cp manifests/01-podinfo-v1.yaml manifests/02-ingress.yaml ~/lab/
   cd ~/lab && git add -A && git commit -m "Lab 1: podinfo behind a plain Ingress"
   ```

---

# What Ingress did *not* give us

- Header, method, or query-parameter matching
- Traffic splitting / weighted backends (canary, blue-green)
- Request or response header manipulation
- URL rewrite and redirect (as first-class fields)
- Anything that is not HTTP/HTTPS — no TCP, UDP, gRPC
- Safe cross-namespace references
- Any way to know *why* your rule is not working

---

# The annotation explosion (Traefik)

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.middlewares: demo-strip-prefix@kubernetescrd
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.priority: "100"
    traefik.ingress.kubernetes.io/service.serversscheme: https
    traefik.ingress.kubernetes.io/service.weight: "10"
```

- **Untyped string syntax** — no schema validation, no `kubectl explain`, no admission checks
- **Brittle provider syntax** — `namespace-name@kubernetescrd` silently fails on typos
- **CRD fragmentation** — basic routing forces vendors to build proprietary CRDs (`Middleware`, `IngressRoute`) attached via opaque annotations

<!--
Presenter note:
Show how Traefik handled Ingress limitations: instead of config-snippets, Traefik
invented external CRDs attached through string lists with @kubernetescrd suffixes.
-->

---

<!-- _class: lab -->

# Lab 2.1 — Path Rewrite with Annotations

**Goal:** Route `/shop` requests to podinfo root `/` using Ingress annotations.

1. **Traefik requires a proprietary Middleware CRD:**
   ```bash
   kubectl apply -f manifests/03-middleware-strip.yaml
   ```
2. **Apply Ingress with Traefik annotation:**
   ```bash
   kubectl apply -f manifests/02-ingress-with-rewrite.yaml
   ```
3. **Verify:**
   ```bash
   curl -s -H 'Host: podinfo.lab' "$GW_URL/shop" | jq -r .message   # VERSION ONE
   ```

Notice the annotation syntax: `demo-strip-shop@kubernetescrd`. A typo in the namespace or provider suffix fails silently.

---

<!-- _class: lab -->

# Lab 2.2 & 2.3 — Canary with Traefik IngressRoute

**Goal:** Configure a working 90/10 canary split using Traefik's IngressRoute CRD and observe vendor lock-in.

1. **Deploy podinfo v2 (canary backend, orange color):**
   ```bash
   kubectl apply -f manifests/04-podinfo-v2.yaml
   ```
2. **In Traefik, canary requires a proprietary IngressRoute CRD:**
   ```bash
   kubectl apply -f manifests/05-ingress-canary.yaml
   ```
3. **Measure traffic distribution (50 requests):**
   ```bash
   for i in $(seq 1 50); do
     curl -s -H 'Host: podinfo.lab' "$GW_URL/shop" | jq -r .message
   done | sort | uniq -c
   # Expected: 45 VERSION ONE (90%) / 5 VERSION TWO (10%)
   ```

*Lesson:* To do a simple canary in Ingress, you had to abandon the standard Kubernetes API and adopt Traefik-specific CRDs.

---

<!-- _class: lab -->

# Lab 2.4 — The RBAC Delegation Problem

**Goal:** Delegate path routing to the application team in `demo`, then observe the security gap.

1. **Grant developer permission to manage Ingress in `demo`:**
   ```bash
   kubectl apply -f manifests/06-rbac-ingress.yaml
   DEV="--as=system:serviceaccount:demo:dev"
   kubectl $DEV -n demo auth can-i update ingress   # yes
   ```
2. **The Security Flaw (Domain Hijack):** Developer can hijack a platform domain (`billing.podinfo.lab`):
   ```bash
   kubectl $DEV -n demo patch ingress podinfo --type=json \
     -p '[{"op":"replace","path":"/spec/rules/0/host","value":"billing.podinfo.lab"}]'
   # Test live: Developer now intercepts traffic for billing.podinfo.lab!
   curl -s -H 'Host: billing.podinfo.lab' "$GW_URL/shop" | jq -r .message # VERSION ONE
   ```
3. **The Flaw:** Ingress cannot restrict which hostnames or TLS secrets a tenant namespace may claim.
4. **Restore & Commit Lab 2:**
   ```bash
   kubectl apply -f manifests/02-ingress-with-rewrite.yaml
   cp manifests/03-middleware-strip.yaml manifests/04-podinfo-v2.yaml \
      manifests/05-ingress-canary.yaml manifests/06-rbac-ingress.yaml ~/lab/
   cd ~/lab && git add -A && git commit -m "Lab 2: annotations, canary, and RBAC flaw"
   ```

---

# Portability was the promise. It did not hold.

The *same* intent, three controllers:

| Controller | Rewrite | Canary |
|---|---|---|
| ingress-nginx | `nginx.ingress.kubernetes.io/rewrite-target` | `canary` + `canary-weight` |
| Traefik | `traefik.ingress.kubernetes.io/router.middlewares` → CRD | Middleware / TraefikService CRD |
| HAProxy | `haproxy.org/path-rewrite` | `haproxy.org/blue-green-balance` |

- The `Ingress` object was portable. **The configuration was not.**
- Migrating controllers meant rewriting every manifest
- Vendors reinvented CRDs anyway (Middleware, TraefikService, ...)

---

# One resource, three personas

A single `Ingress` object mixes concerns owned by different teams:

- **TLS certificate reference** → security / platform team
- **Hostname and DNS** → platform team
- **Path routing to backends** → application team
- **Timeouts, body size, rate limits** → somewhere between all three

RBAC is `verb` × `resource` × `namespace`. It cannot express *"devs may change paths but not TLS."*

**Result:** either app teams get edit rights on the whole object, or every routing change is a platform ticket.

---

# 2017–2020: The service mesh fork

When Istio (2017) and Linkerd ignited the **Service Mesh hype**, they needed what Kubernetes lacked: L7 routing, canary weights, retries, and mTLS between services.

Because `Ingress` was frozen in beta and `kube-proxy` was strictly L4, **every mesh invented its own API**:

- **Istio** → `VirtualService`, `DestinationRule`, `Gateway`
- **Linkerd** → `ServiceProfile`, `TrafficSplit` (SMI)
- **Consul** → `ServiceRouter`, `ServiceSplitter`

### The Result: Architectural Split-Brain

- **North-South (Edge Ingress)** → `Ingress` + opaque vendor annotations
- **East-West (Service-to-Service)** → Complex, proprietary mesh CRDs

<span class="warn">Two incompatible APIs in the same cluster for the exact same routing intent.</span>

---

# 2015–2020: Two parallel timelines

### Track 1: Ingress v1 was stuck in beta (2015–2020)
- **Nov 2015 (K8s 1.1):** Introduced as `extensions/v1beta1`
- **Mar 2019 (K8s 1.14):** Moved to `networking.k8s.io/v1beta1`
- **Aug 2020 (K8s 1.19):** Graduated to GA (`networking.k8s.io/v1`) & **frozen**
- *Nearly 5 years in beta:* Nobody was comfortable declaring the 2015 single-resource shape permanent.

### Track 2: The "Ingress v2" reboot (2019–Present)
- **Nov 2019 (KubeCon San Diego):** SIG-Network launches the **"Ingress v2"** working group
- **2020:** Formalized as **Service APIs**, then renamed **Gateway API**
- **Oct 2023:** Gateway API reaches **v1.0 GA** (`GatewayClass`, `Gateway`, `HTTPRoute`)

<span class="warn">Ingress was graduated to GA in 2020 to provide a stable legacy baseline while Gateway API was built.</span>

---

# Gateway API timeline to 2026

| Date | Release | Milestone |
|---|---|---|
| 2020–2023 | v0.x | API shape iterates; ReferenceGrant, GRPCRoute appear |
| **Oct 2023** | **v1.0** | **GatewayClass, Gateway, HTTPRoute reach GA (v1)** |
| May 2024 | v1.1 | GRPCRoute GA; **service mesh support GA** (GAMMA) |
| 2024–2025 | v1.2 – v1.4 | BackendTLSPolicy, timeouts, retries, mirroring |
| **Feb 2026** | **v1.5** | ListenerSet, TLSRoute, CORS filter, ReferenceGrant → Standard |
| **Jun 2026** | **v1.6** | **TCPRoute + UDPRoute GA**; experimental split to `gateway.networking.x-k8s.io` |

<span class="small">Latest patch: v1.6.1 (16 July 2026). Standard channel cadence is 4 months.</span>

---

# The road ahead: 2026–2028+

With L4–L7 core routing GA, SIG-Network is expanding into security, observability, and multi-cluster:

- **Native Authentication & AuthZ ([GEP-1494](https://gateway-api.sigs.k8s.io/geps/gep-1494/)):** Standard `ExternalAuth` filter (OIDC, OAuth2, JWT, `ext_authz`) eliminating proprietary auth middlewares
- **Standardized Telemetry ([GEP-4768](https://gateway-api.sigs.k8s.io/geps/gep-4768/)):** Declarative OpenTelemetry tracing and access logging across all implementations
- **Multi-Cluster Ingress ([GEP-1748](https://gateway-api.sigs.k8s.io/geps/gep-1748/)):** Routing across clusters via `ServiceImport` (MCS-API)
- **Non-Service Backends ([GEP-4894](https://gateway-api.sigs.k8s.io/geps/gep-4894/)):** Direct routing to S3 storage buckets, serverless functions, and external FQDNs
- **Diagnostic Tooling ([GEP-2722](https://gateway-api.sigs.k8s.io/geps/gep-2722/)):** Dedicated `gwctl` CLI to inspect topology graphs and status conditions

<!--
Presenter note:
Emphasize that Gateway API is becoming the universal L4-L7 application networking
platform for Kubernetes — absorbing security, telemetry, and multi-cluster routing.
-->

---

<!-- _class: divider -->

# Part 2

## Why Gateway API: The Resource Model

---

# The resource model

```
GatewayClass          "what implementation"        cluster-scoped
    ▲                  (like StorageClass)
    │ gatewayClassName
    │
  Gateway             "where traffic enters"       namespaced
    ▲                  listeners, ports, TLS, IP
    │ parentRefs
    │
  HTTPRoute           "how requests are routed"    namespaced
  GRPCRoute            matches, filters, backends
  TCPRoute
    │ backendRefs
    ▼
  Service / other backend
```

Three objects instead of one — **because there are three decisions, made by three people.**

---

<!-- _class: lab -->

# Lab 3.1 & 3.2 — Enable Gateway API in RKE2

**Goal:** Turn on Traefik's Gateway API provider in RKE2.

1. **Check pre-installed CRDs:**
   ```bash
   kubectl get crd | grep gateway.networking.k8s.io
   # Notice: CRDs are installed by rke2-traefik-crd, but GatewayClass is empty!
   kubectl get gatewayclass
   ```
2. **Enable Traefik Gateway Provider via HelmChartConfig:**
   ```bash
   kubectl apply -f manifests/09-helmchartconfig-traefik.yaml
   ```
3. **Wait for helm-controller to roll out Traefik:**
   ```bash
   kubectl -n kube-system rollout status daemonset/rke2-traefik --timeout=3m
   ```

---

<!-- _class: lab -->

# Lab 3.3 — Verify Gateway API Provider

1. **Verify GatewayClass registration:**
   ```bash
   kubectl get gatewayclass
   ```
   *Expected output:*
   ```text
   NAME      CONTROLLER                      ACCEPTED   AGE
   traefik   traefik.io/gateway-controller   True       15s
   ```
2. **Inspect supported API resources:**
   ```bash
   kubectl api-resources --api-group=gateway.networking.k8s.io
   ```
   You now have: `gateways`, `gatewayclasses`, `httproutes`, `grpcroutes`, `referencegrants`.

---

# Role-oriented design

| Persona | Owns | Typical org |
|---|---|---|
| **Infrastructure provider** | `GatewayClass` | SUSE / cloud vendor / platform vendor |
| **Cluster operator** | `Gateway` | Platform / SRE team |
| **Application developer** | `HTTPRoute`, `GRPCRoute` | Product teams |

RBAC now maps cleanly:

```bash
# Platform team: full control of entry points
kubectl create role gw-operator --verb='*' --resource=gateways.gateway.networking.k8s.io

# App team: routing only, in their own namespace
kubectl create role route-editor -n team-a \
  --verb='*' --resource=httproutes.gateway.networking.k8s.io
```

**No ticket required to change a path. No app team able to change a TLS certificate.**

---

# Status conditions — you can finally debug

```bash
$ kubectl describe httproute podinfo
Status:
  Parents:
    Conditions:
      Type:     Accepted
      Status:   True
      Reason:   Accepted
      Type:     ResolvedRefs
      Status:   False
      Reason:   BackendNotFound
      Message:  Service "shop-api" not found
```

Every Route reports, **per parent Gateway**:
- `Accepted` — did the Gateway take this route?
- `ResolvedRefs` — do all backends and grants resolve?

**With Ingress you read controller logs and guessed.**

---

<!-- _class: lab -->

# Lab 4.1 & 4.2 — Gateway & HTTPRoute Handshake

**Goal:** Establish the role-separated Gateway and HTTPRoute baseline.

1. **Clean legacy Ingress-era objects & deploy Gateway in `infra`:**
   ```bash
   kubectl delete -f manifests/08-cleanup-ingress-era.yaml --ignore-not-found
   kubectl apply -f manifests/10-gateway.yaml   # port 8000 binds Traefik web entrypoint
   ```
2. **Developer creates HTTPRoute in `demo` & observes rejection:**
   ```bash
   kubectl apply -f manifests/11-httproute.yaml
   kubectl -n demo describe httproute podinfo  # Reason: NotAllowedByListeners (from: Same)
   ```
3. **Operator opens listener across namespaces (`from: All`):**
   ```bash
   kubectl -n infra patch gateway web --type=json \
     -p '[{"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces/from","value":"All"}]'
   ```
4. **Verify handshake & test routing:**
   ```bash
   kubectl -n demo describe httproute podinfo  # Accepted: True, ResolvedRefs: True
   curl -s -H 'Host: podinfo.lab' "$GW_URL/" | jq -r .message   # VERSION ONE
   ```

---

<!-- _class: lab -->

# Lab 4.3a — Isolated URL Rewrite Filter

**Goal:** Route `/shop` with `URLRewrite` while ensuring `/` is NOT exposed.

1. **Apply HTTPRoute with `/shop` rule ONLY:**
   ```bash
   kubectl apply -f manifests/11-httproute-rewrite-1.yaml
   ```
2. **Verify isolated scoping:**
   ```bash
   # /shop is rewritten to / on the pod -> Returns VERSION ONE (200 OK):
   curl -s -H 'Host: podinfo.lab' "$GW_URL/shop" | jq -r .message

   # / is NOT matched by any rule -> Traefik returns 404:
   curl -s -o /dev/null -w "%{http_code}\n" -H 'Host: podinfo.lab' "$GW_URL/"   # 404
   ```

*Lesson:* Unlike Ingress annotations (which bleed globally across an object), Gateway API rules and filters are strictly isolated.

---

<!-- _class: lab -->

# Lab 4.3b — Multi-Rule Coexistence

**Goal:** Cleanly combine rewritten paths (`/shop`) and plain paths (`/`) in one object.

1. **Apply HTTPRoute with BOTH rules:**
   ```bash
   kubectl apply -f manifests/11-httproute-rewrite-2.yaml
   ```
2. **Verify both paths answer independently:**
   ```bash
   curl -s -H 'Host: podinfo.lab' "$GW_URL/shop" | jq -r .message   # VERSION ONE (rewritten)
   curl -s -H 'Host: podinfo.lab' "$GW_URL/"     | jq -r .message   # VERSION ONE (plain)
   ```
3. **Spec-mandated precedence:**
   Longest prefix match (`/shop`) is evaluated first; `/` acts as the root fallback.

---

<!-- _class: lab -->

# Lab 4.4 — RBAC Delegation & Security Proof

**Goal:** Prove that the developer can manage routes but is strictly blocked from modifying Gateway infrastructure.

1. **Apply scoped developer RBAC (`Role: route-editor`):**
   ```bash
   kubectl apply -f manifests/12-rbac-gateway.yaml
   DEV="--as=system:serviceaccount:demo:dev"
   ```
2. **Action 1 (Intended): Developer updates their HTTPRoute in `demo`:**
   ```bash
   kubectl $DEV -n demo patch httproute podinfo --type=merge \
     -p '{"metadata":{"annotations":{"updated-by":"dev"}}}'   # Succeeded!
   ```
3. **Action 2 (Forbidden): Developer attempts to patch Gateway in `infra`:**
   ```bash
   kubectl $DEV -n infra patch gateway web --type=json \
     -p '[{"op":"replace","path":"/spec/listeners/0/port","value":9000}]'
   # Error from server (Forbidden): User cannot patch resource "gateways" in namespace "infra"
   ```
4. **Commit Lab 4:**
   ```bash
   cp manifests/10-gateway.yaml manifests/11-httproute.yaml manifests/12-rbac-gateway.yaml ~/lab/
   cd ~/lab && git add -A && git commit -m "Lab 4: Gateway API baseline, typed rewrite, scoped RBAC"
   ```

---

<!-- _class: divider -->

# Part 3

## Expressiveness: Canary & gRPC

---

# Expressiveness — matching & filters

```yaml
rules:
  - matches:
      - path: { type: PathPrefix, value: /api/v2 }
        method: POST
        headers:
          - { name: x-tenant, value: acme }
    filters:
      - type: RequestHeaderModifier
        requestHeaderModifier:
          set: [{ name: x-env, value: prod }]
      - type: URLRewrite
        urlRewrite:
          path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
    backendRefs:
      - name: api-v2
        port: 8080
```

Typed. Validated at admission. Discoverable with `kubectl explain`.

---

# Expressiveness — traffic splitting

```yaml
rules:
  - backendRefs:
      - name: podinfo-v1
        port: 9898
        weight: 90
      - name: podinfo-v2
        port: 9898
        weight: 10
```

- Canary and blue-green **without a service mesh**
- Weights are a first-class field — Argo Rollouts and Flux drive them natively
- Compare: Ingress required a *second, duplicate* object with vendor annotations

---

<!-- _class: lab -->

# Lab 5.1 & 5.2 — Weighted Canary & Header Routing

1. **Apply 90/10 Canary split in a single HTTPRoute:**
   ```bash
   kubectl apply -f manifests/11-httproute-traffic-split.yaml
   ```
2. **Measure traffic distribution:**
   ```bash
   for i in $(seq 1 50); do
     curl -s -H 'Host: podinfo.lab' "$GW_URL/shop" | jq -r .message
   done | sort | uniq -c
   ```
3. **Add deterministic targeting via HTTP headers (`X-Canary: always`):**
   ```bash
   kubectl apply -f manifests/11-httproute-header-routing.yaml
   curl -s -H 'Host: podinfo.lab' -H 'X-Canary: always' "$GW_URL/shop" | jq -r .message
   # Always returns "VERSION TWO"
   ```

---

# Beyond HTTP: Multi-protocol routing

| Resource | Status | Use case |
|---|---|---|
| `HTTPRoute` | GA (v1.0) | HTTP/HTTPS routing, headers, rewrites |
| `GRPCRoute` | GA (v1.1) | gRPC service and method routing |
| `TLSRoute` | Standard (v1.5) | SNI-based TLS passthrough (L4) |
| `TCPRoute` | **GA (v1.6)** | Raw L4 TCP stream proxying |
| `UDPRoute` | **GA (v1.6)** | Raw L4 UDP datagram proxying |

One API, one Gateway, one RBAC model — for everything entering the cluster.

---

<!-- _class: lab -->

# Lab 6.1 & 6.2 — Deploy gRPC & GRPCRoute

1. **Deploy podinfo with gRPC enabled (`port: 9999` & `appProtocol: h2c`):**
   ```bash
   kubectl apply -f manifests/20-podinfo-grpc.yaml
   kubectl -n demo rollout status deploy/podinfo-grpc
   ```
2. **Deploy GRPCRoute with method matching:**
   ```bash
   kubectl apply -f manifests/21-grpcroute.yaml
   ```
3. **Inspect the GRPCRoute specification:**
   ```yaml
   matches:
     - method:
         service: grpc.health.v1.Health
         method: Check
   ```

---

<!-- _class: lab -->

# Lab 6.3 & 6.4 — Test gRPC with grpcurl

1. **Call gRPC health check endpoint through Traefik Gateway:**
   ```bash
   grpcurl -plaintext -authority grpc.podinfo.lab \
     "${GW_URL#http://}" grpc.health.v1.Health/Check
   ```
   *Expected response:* `{"status": "SERVING"}`
2. **Break method matching (simulate typo):**
   ```bash
   kubectl -n demo patch grpcroute podinfo-grpc --type=json \
     -p '[{"op":"replace","path":"/spec/rules/0/matches/0/method/method","value":"Watch"}]'
   # Re-run Check -> Returns (Unimplemented / Routing error)
   ```
3. **Restore and commit:**
   ```bash
   kubectl apply -f manifests/21-grpcroute.yaml
   cp manifests/20-podinfo-grpc.yaml manifests/21-grpcroute.yaml ~/lab/
   cd ~/lab && git add -A && git commit -m "Lab 6: multi-protocol routing with GRPCRoute"
   ```

---

<!-- _class: divider -->

# Part 4

## Multi-Tenancy & Safe Delegation

---

# Safe cross-namespace: `ReferenceGrant`

**Problem with Ingress:** an Ingress in namespace A referencing a Secret or Service elsewhere is either forbidden or unsafely permitted.

**Gateway API:** references across namespaces are **denied by default**, and the *target* namespace opts in.

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-team-a
  namespace: team-b          # namespace that OWNS the Service
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: team-a      # namespace permitted to reference it
  to:
    - group: ""
      kind: Service
      name: app
```

**The owner grants. The consumer cannot self-authorise.**

---

# Who may attach to my Gateway?

```yaml
listeners:
  - name: web
    protocol: HTTP
    port: 8000
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: "true"
      kinds:
        - kind: HTTPRoute
```

- Operator controls **which namespaces**, **which route kinds**, **which hostnames**
- Route authors cannot hijack a hostname outside the listener's pattern
- Solves the shared-ingress multi-tenancy problem that Rancher Projects create

---

<!-- _class: lab -->

# Lab 7.1 & 7.2 — Multi-Tenant Setup

1. **Deploy two tenant namespaces (`team-a` and `team-b`):**
   ```bash
   kubectl apply -f manifests/29-tenants.yaml
   kubectl -n team-a rollout status deploy/app
   kubectl -n team-b rollout status deploy/app
   ```
2. **Configure shared Gateway with cross-namespace listener permissions:**
   ```bash
   kubectl apply -f manifests/30-gateway-shared.yaml
   ```
3. **Inspect `allowedRoutes` on Gateway:**
   `allowedRoutes.namespaces.from: All` allows routes from `team-a` and `team-b` to attach.

---

<!-- _class: lab -->

# Lab 7.3 & 7.4 — Route Attachment & Delegation

1. **Team A attaches their HTTPRoute to shared Gateway:**
   ```bash
   kubectl apply -f manifests/30-httproute-team-a.yaml
   ```
2. **Verify traffic routing:**
   ```bash
   curl -s -H 'Host: a.podinfo.lab' "$GW_URL/" | jq -r .message   # TEAM A
   ```
3. **Attempt cross-namespace backend reference without grant:**
   Edit `team-a` HTTPRoute to send `/shared` traffic to `service/app` in `team-b`:
   ```bash
   kubectl -n team-a describe httproute app
   # Status shows: ResolvedRefs: False, Reason: RefNotPermitted
   ```

---

<!-- _class: lab -->

# Lab 7.5 & 7.6 — Granting Access with ReferenceGrant

1. **Team B explicitly permits Team A via `ReferenceGrant`:**
   ```bash
   kubectl apply -f manifests/31-referencegrant.yaml
   ```
2. **Observe status resolution:**
   ```bash
   kubectl -n team-a describe httproute app
   # ResolvedRefs transitions to True!
   ```
3. **Commit Lab 7:**
   ```bash
   cp manifests/29-tenants.yaml manifests/30-gateway-shared.yaml \
      manifests/30-httproute-team-a.yaml manifests/31-referencegrant.yaml ~/lab/
   cd ~/lab && git add -A && git commit -m "Lab 7: multi-tenancy and ReferenceGrant"
   ```

---

<!-- _class: divider -->

# Part 5

## Architecture, Migration & Production Reality

---

# Mesh convergence (GAMMA)

Since v1.1, a `Service` can be a `parentRef`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cart-retry
  namespace: shop
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: cart-service
      port: 8080
  rules:
    - timeouts:
        request: 500ms
      backendRefs:
        - name: cart-service
          port: 8080
```

**North-south (ingress) and east-west (mesh) now use the same API.**

---

# Architectural divide: Static vs Dynamic

| Architecture | Implementations | How it works |
|---|---|---|
| **Static infrastructure** | **Traefik**, Cilium | One ingress controller deployment; Gateways bind to existing listeners/ports |
| **Dynamic infrastructure** | **Envoy Gateway**, NGF | Creating a `Gateway` object actively spawns a new Envoy Deployment + ServiceLB |

**RKE2 with Traefik uses static infrastructure:**
- You manage listeners on the existing Traefik DaemonSet/Service
- Highly resource-efficient, predictable memory and port binding
- Contrast with Envoy Gateway which provisions dedicated proxies per Gateway object

---

# Migration strategy from Ingress

1. **Audit existing Ingresses:**
   - How many rely on custom annotations (`rewrite`, `cors`, `canary`)?
   - How many use `configuration-snippet` (must be converted to extension filters)?
2. **Automated translation tool:**
   - Use [kubernetes-sigs/ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway):
     ```bash
     ingress2gateway print --providers ingress-nginx > gateway-resources.yaml
     ```
3. **Coexistence:**
   - Ingress and Gateway API run side-by-side on the same Traefik data plane without conflict.

---

# Gateway API Tooling Ecosystem

The Kubernetes SIG-Network subproject maintains dedicated tools to manage, migrate, and visualize Gateway API:

- **`gwctl` ([kubernetes-sigs/gwctl](https://github.com/kubernetes-sigs/gwctl)):**
  Official CLI tool to inspect, describe, and visualize Gateway graphs, listeners, and policy bindings
- **`ingress2gateway` ([kubernetes-sigs/ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway)):**
  Automated migration CLI converting legacy Ingress manifests + provider annotations to Gateway API
- **`Headlamp` ([kubernetes-sigs/headlamp](https://github.com/kubernetes-sigs/headlamp)):**
  Kubernetes web dashboard with native, real-time Gateway API topological map views
- **`policy-machinery` ([Kuadrant/policy-machinery](https://github.com/Kuadrant/policy-machinery)):**
  Framework for validating and implementing hierarchical Policy Attachments (Defaults & Overrides)

---

# Deep-Dive: gwctl vs. kubectl

`kubectl` requires multiple `get` and `describe` commands across namespaces to trace routing paths.

`gwctl` builds the **complete relationship tree** in one command:

```text
$ gwctl describe gateway web -n infra
Gateway: infra/web
├── Listener: web (HTTP :80) [Accepted: True]
│   ├── Route: demo/podinfo [Accepted: True, ResolvedRefs: True]
│   │   ├── Backend: demo/podinfo-v1:9898 (Weight: 90)
│   │   └── Backend: demo/podinfo-v2:9898 (Weight: 10)
│   └── Route: team-a/app [Accepted: True, ResolvedRefs: True]
└── Listener: websecure (HTTPS :443) [Accepted: True]
```

- Instant diagnosis of `NotAllowedByListeners` and `RefNotPermitted` errors
- Shows effective attached policies (timeouts, retries, auth) at every level

---

<!-- _class: lab -->

# Lab: Gateway API Tooling in Action

**Goal:** Use `ingress2gateway` for automated migration and `gwctl` to inspect cluster topology.

1. **Automated Migration with `ingress2gateway`:**
   ```bash
   ingress2gateway print --providers ingress-nginx --input-file manifests/02-ingress.yaml
   ```
   *Watch it translate our Lab 1 Ingress into standard Gateway and HTTPRoute YAML!*

2. **Inspect Cluster Graph with `gwctl`:**
   ```bash
   gwctl get gateways -A
   gwctl get httproutes -A
   gwctl describe gateway web -n infra
   ```

3. **Explore Multi-Tenant Relationships:**
   ```bash
   gwctl describe httproute podinfo -n demo
   gwctl describe httproute app -n team-a
   ```

---

# The honest downsides of Gateway API

- **More objects to manage:** 3 YAML files instead of 1 for a simple exposure
- **CRD lifecycle overhead:** Upgrades must consider CRD versions and channel separation
- **Ecosystem maturity:** Tools like ExternalDNS and Cert-Manager support Gateway API, but legacy Helm charts still ship `Ingress` templates
- **Implementation variance on extended features:** Core is 100% portable; regex path matching and custom timeouts require conformance profile checks

---

# When to stay on Ingress

- Simple cluster with a single development team and no multi-tenant delegation needs
- Basic HTTP path routing without canary, gRPC, or header matching requirements
- Established GitOps pipelines using mature `Ingress` charts that work reliably

**When to move to Gateway API:**
- Multi-team clusters where platform and app responsibilities must be decoupled
- Modern protocols needed (gRPC, WebSocket, TCP/UDP)
- Advanced traffic splitting, header injection, or path rewrites without proprietary annotations

---

# The session in one command

```bash
cd ~/lab
git log --oneline
git diff HEAD~6 HEAD
```

**What you will see in that diff:**
- 10+ unstructured annotations replaced by clean, typed fields
- Split-brain ingress files consolidated into weighted backends
- Single-resource security flaws replaced by role-scoped RBAC
- Multi-protocol gRPC and cross-namespace ReferenceGrant delegation

---

<!-- _class: lead -->

# Summary

1. **Ingress is feature-frozen** — Gateway API is the standard for Kubernetes service networking.
2. **Role-oriented architecture** decouples Platform Operator (`Gateway`) from App Developer (`HTTPRoute`).
3. **On RKE2, Traefik provides built-in Gateway API support** — enabled with a simple `HelmChartConfig`.

**Questions & Discussion**

---

<!-- _class: divider -->

# Appendices

## Reference & Additional Labs

---

# Appendix A — TLS Termination

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: infra
spec:
  gatewayClassName: traefik
  listeners:
    - name: websecure
      port: 8443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: podinfo-tls
            namespace: infra
      allowedRoutes:
        namespaces:
          from: All
```

TLS secret is owned in `infra` namespace; `HTTPRoute` authors cannot modify certificates.

---

# Appendix B — Gateway API Condition Dictionary

| Condition | Reason | What it means |
|---|---|---|
| `Accepted: True` | `Accepted` | Parent Gateway validated and accepted this route |
| `Accepted: False` | `NotAllowedByListeners` | Gateway listener rejected route namespace or hostname |
| `ResolvedRefs: True` | `ResolvedRefs` | All backend Services and ReferenceGrants exist |
| `ResolvedRefs: False` | `BackendNotFound` | Referenced backend Service does not exist |
| `ResolvedRefs: False` | `RefNotPermitted` | Cross-namespace reference without a `ReferenceGrant` |
| `Programmed: True` | `Programmed` | Data plane has successfully synchronized configuration |

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Thank You

## Kubernetes Gateway API on RKE2
SUSE Consulting EMEA
