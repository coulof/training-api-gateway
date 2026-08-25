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
    padding: 55px 70px;
  }
  section h1 {
    color: var(--suse-jungle);
    font-size: 1.55em;
    border-bottom: 4px solid var(--suse-green);
    padding-bottom: 12px;
    margin-bottom: 24px;
  }
  section h2 { color: var(--suse-green); font-size: 1.15em; }
  section h3 { color: var(--suse-jungle); font-size: 1.0em; }
  section code { font-size: 0.82em; background: #F2F7F5; }
  section pre { font-size: 0.66em; line-height: 1.35; background: #F2F7F5;
                border-left: 5px solid var(--suse-green); padding: 14px 18px; }
  section table { font-size: 0.80em; }
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
  .small { font-size: 0.80em; color: var(--suse-grey); }
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

| | Block | Labs |
|---|---|---|
| 1 | Ingress: what it gave us, what it cost | **1–2** |
| 2 | Why Gateway API — the resource model | **3–4** |
| — | *Break* | |
| 3 | Expressiveness: canary, headers, gRPC | **5–6** |
| 4 | Multi-tenancy and safe references | **7** |
| 5 | RKE2 reality, migration strategy, wrap | — |

Seven labs. One application — **podinfo** — configured first the Ingress way, then the
Gateway API way, tracked in git so you can diff the two at the end.

<span class="small">Falling behind is fine: every lab starts from a known state and says what it assumes.</span>

---

<!-- _class: lab -->

# Your environment

- One **single-node RKE2** cluster each, driven **entirely from a kubeconfig**
- No SSH. No root. No node access. Everything is `kubectl`.
- `ingress-controller: traefik` + `enable-servicelb: true`
- **Gateway API is deliberately NOT enabled yet** — you turn it on in Lab 3
- Workload: **podinfo**, v1 and v2

```bash
export KUBECONFIG=./gwapi-lab.kubeconfig
./scripts/00-check-prereqs.sh          # tooling, RBAC, Traefik, data path

# one reachable URL for every curl in every lab
kubectl -n kube-system port-forward svc/traefik 8080:80 &
export GW_URL="http://127.0.0.1:8080"
```

<span class="small">If Traefik's LoadBalancer address is routable from your machine, use that instead — it exercises the real data path.</span>

---

<!-- _class: divider -->

# Part 1

## History

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
  name: shop
spec:
  ingressClassName: nginx
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: shop-api
                port:
                  number: 8080
```

Genuinely useful. Genuinely portable. **For exactly this.**

---

<!-- _class: lab -->

# Lab 1 — Make it work, the 2015 way

**20 min** · Prove the cluster works, and meet the artifact we will carry all session.

1. Verify RKE2, Traefik, and that **ServiceLB** gave Traefik a real address
2. `helm template` **podinfo's own chart** — read what it generates
3. **Take ownership:** save a trimmed Deployment / Service / Ingress into `~/lab/`
4. `git init` — from here on, every change is a diff you can show

```bash
kubectl -n kube-system get svc traefik      # EXTERNAL-IP must not be <pending>
curl -s -H 'Host: podinfo.lab' $GW_URL/ | jq -r .message
```

**Checkpoint:** `VERSION ONE` comes back, and you own the YAML — not Helm.

<!--
Two jobs here. One: smoke-test every VM before anything can go wrong later.
Two: establish the artifact. Everything from Lab 2 onward is an edit to files
the participant owns, tracked in git, so the Ingress-era and Gateway-era configs
can be diffed side by side at the end. That diff is the punchline of the session.
Do not let anyone skip the git init.
-->

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

# The annotation explosion

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"
    nginx.ingress.kubernetes.io/proxy-body-size: 50m
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Request-Id: $req_id";
```

- Untyped opaque strings — no schema, no `kubectl explain`, no admission validation
- Typo silently does nothing
- `configuration-snippet` = arbitrary NGINX config injected from a namespace-scoped object

<span class="warn">This last one has been a recurring source of CVEs and privilege-escalation findings.</span>

<!--
Worth 30 seconds: the config-snippet class of vulnerability is exactly what happens
when you let an app-team-owned object inject raw dataplane config. It is an
architectural consequence of the single-resource model, not an NGINX bug.
-->

---

<!-- _class: lab -->

# Lab 2 — Live the annotation problem

**25 min** · Do the two most common real-world tasks. Feel what they cost.

1. **Path rewrite** — needs a `Middleware` CRD *plus* an annotation *plus* the
   `namespace-name@kubernetescrd` naming convention. Get one wrong: silent failure.
2. **Canary to v2** — a **second, duplicate Ingress object** carrying weight annotations
3. Measure the actual split with a request loop
4. Grant a "developer" edit rights on Ingress — then watch them change the **TLS host**

**Checkpoint:** the canary works, and you can name three things wrong with *how*.

<!--
This is the emotional core of Part 1. Do not rush it and do not help too fast —
let people mistype the @kubernetescrd suffix and get a silent 404. That
experience is what makes the typed-field argument land 20 minutes later.

Step 4 is the RBAC demo: one Ingress object mixes dev-owned routing and
platform-owned TLS, so any Role that permits the first permits the second.
Ask the room how they work around this today. The answer is always "a ticket".
-->

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

<!--
This is the slide that lands with architects. Ask the room: who here has a Jira
queue for ingress changes? Usually a few hands. That queue exists because of
this design, not because your platform team likes tickets.
-->

---

# The service mesh fork

Meshes needed exactly what Ingress lacked — so they built it themselves:

- Istio → `VirtualService`, `DestinationRule`, `Gateway`
- Linkerd → `ServiceProfile`
- Consul → `ServiceRouter`, `ServiceSplitter`

Consequence: **two routing APIs in the same cluster**

- North-south (into the cluster) → `Ingress` + annotations
- East-west (service to service) → mesh CRDs

Different syntax, different semantics, different RBAC, for the same conceptual operation.

---

# Five years in beta

- 2015 — `extensions/v1beta1` in Kubernetes 1.1
- 2019 — moved to `networking.k8s.io/v1beta1`
- **2020 — GA at last, in Kubernetes 1.19**

Nearly five years in beta is the community telling you something: *nobody was comfortable promising this API was the right shape.*

By the time it went GA, the replacement effort had already started.

---

# 2019 — the successor begins

- SIG-Network starts work under the name **"Ingress v2"**, then **"Service APIs"**
- Renamed **Gateway API** in 2020
- Explicit design goals from day one:
  - **Role-oriented** — separate resources for separate personas
  - **Portable** — expressiveness in the spec, not in annotations
  - **Expressive** — the common cases are typed fields
  - **Extensible** — a defined mechanism for vendor extension, layered not bolted on

---

# Gateway API timeline

| Date | Release | Milestone |
|---|---|---|
| 2020–2023 | v0.x | API shape iterates; ReferenceGrant, GRPCRoute appear |
| **Oct 2023** | **v1.0** | **GatewayClass, Gateway, HTTPRoute reach GA (v1)** |
| May 2024 | v1.1 | GRPCRoute GA; **service mesh support GA** (GAMMA) |
| 2024–2025 | v1.2 – v1.4 | BackendTLSPolicy, timeouts, retries, mirroring |
| **Feb 2026** | **v1.5** | ListenerSet, TLSRoute, CORS filter, client-cert validation, ReferenceGrant → Standard |
| **Jun 2026** | **v1.6** | **TCPRoute + UDPRoute GA**; experimental split to `gateway.networking.x-k8s.io` |

<span class="small">Latest patch at time of writing: v1.6.1 (16 July 2026). 4-month cadence for Standard channel — verify before you deliver.</span>

---

# Where we are — August 2026

**Standard channel, `gateway.networking.k8s.io/v1`:**

`GatewayClass` · `Gateway` · `HTTPRoute` · `GRPCRoute` · `TCPRoute` · `UDPRoute` · `TLSRoute` · `ReferenceGrant` · `ListenerSet`

**Two release channels:**

- **Standard** — GA resources and fields, backwards-compatible, safe to upgrade
- **Experimental** — everything in Standard *plus* alpha resources and fields; since v1.6 these live in a **separate API group** `gateway.networking.x-k8s.io` with an `X` prefix

<span class="small">The group split in v1.6 means you can no longer accidentally depend on an experimental field while believing you are on Standard.</span>

---

# And Ingress?

- Still GA. Still supported. Still works.
- **Feature-frozen.** No new capability will land in the `Ingress` resource.
- All SIG-Network investment goes to Gateway API.
- Most controllers now ship both, with Gateway API as the strategic path.

**Ingress is not deprecated. It is finished.**

<!--
Be precise here — people will ask "is Ingress deprecated?". No. There is no
deprecation notice, no removal timeline. But nothing new will ever be added.
Plan migrations on your schedule, not in a panic.
-->

---

<!-- _class: divider -->

# Part 2

## Why Gateway API over Ingress

---

# The resource model

```
GatewayClass          "what implementation"        cluster-scoped
    ▲                  (like StorageClass)
    │ gatewayClassName
    │
 Gateway              "where traffic enters"       namespaced
    ▲                  listeners, ports, TLS, IP
    │ parentRefs
    │
 HTTPRoute            "how requests are routed"    namespaced
 GRPCRoute             matches, filters, backends
 TCPRoute
    │ backendRefs
    ▼
 Service / other backend
```

Three objects instead of one — **because there are three decisions, made by three people.**

---

<!-- _class: lab -->

# Lab 3 — Turn on Gateway API

**10 min** · Operator task. Nothing routes yet — we are installing capability.

```bash
# HelmChartConfig, NOT kubectl edit deploy/traefik (helm-controller reverts that)
cat > /var/lib/rancher/rke2/server/manifests/rke2-traefik-config.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: rke2-traefik, namespace: kube-system }
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
EOF
kubectl -n kube-system rollout status deploy/traefik
```

Then **verify**: which CRDs appeared, what `bundle-version` they carry, and what
`GatewayClass` exists that **you did not create**.

<span class="warn">Read the CRD-deletion warning before you ever disable Traefik again.</span>

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
$ kubectl describe httproute shop
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

Gateways report `Accepted`, `Programmed`, and per-listener `ResolvedRefs` + `Conflicted`.

**With Ingress you read controller logs and guessed.**

---

<!-- _class: lab -->

# Lab 4 — Gateway + HTTPRoute

**25 min** · The same app as Lab 1, now with the personas separated.

1. **Operator** creates a `Gateway` in `infra` with `allowedRoutes: from: Same`
2. **Developer** creates an `HTTPRoute` in `demo` — watch it be **rejected**
   (`NotAllowedByListeners`). This is the model working, not a bug.
3. Operator opens the listener. Route attaches. Traffic flows.
4. Redo the Lab 2 rewrite as a typed `URLRewrite` filter — no CRD, no annotation
5. Redo the Lab 2 RBAC test: give the dev `httproutes` only. Watch TLS stay safe.

```bash
kubectl -n demo describe httproute podinfo    # read the conditions, always
```

**Checkpoint:** `git diff` shows the annotation stack replaced by typed fields.

---

# Expressiveness — matching

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /api/v2
        method: POST
        headers:
          - name: x-tenant
            type: Exact
            value: acme
        queryParams:
          - name: beta
            value: "true"
    backendRefs:
      - name: api-v2
        port: 8080
```

Typed. Validated at admission. Discoverable with `kubectl explain`.

**No annotation could ever express this.**

---

# Expressiveness — filters

```yaml
filters:
  - type: RequestHeaderModifier
    requestHeaderModifier:
      set:    [{ name: x-env, value: prod }]
      remove: [ x-internal-debug ]
  - type: URLRewrite
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
  - type: RequestMirror
    requestMirror:
      backendRef: { name: shadow-api, port: 8080 }
```

Also standard: `ResponseHeaderModifier`, `RequestRedirect`, `CORS` (since v1.5), `ExtensionRef` for vendor filters.

---

# Expressiveness — traffic splitting

```yaml
rules:
  - backendRefs:
      - name: shop-v1
        port: 8080
        weight: 90
      - name: shop-v2
        port: 8080
        weight: 10
```

- Canary and blue-green **without a service mesh**
- Weights are a first-class field — Argo Rollouts and Flux drive them natively
- Compare: `nginx.ingress.kubernetes.io/canary-weight` on a *second, duplicate* Ingress object

---

<!-- _class: lab -->

# Lab 5 — Canary, properly

**20 min** · The Lab 2 task again. Compare the mechanism, not just the result.

1. One HTTPRoute, `backendRefs` weights 90/10 — **no second object**
2. Shift to 50/50, then 0/100, with `kubectl patch`. Measure each time.
3. Add deterministic targeting: `headers: x-canary: "true"` → always v2
4. Inject a response header so you can see which rule served you

```bash
for i in $(seq 1 100); do
  curl -s -H 'Host: podinfo.lab' $GW_URL/ | jq -r .message
done | sort | uniq -c
```

**Checkpoint:** `git diff` the Lab 2 canary against this one. Two objects and four
annotations became four lines in one object.

---

# Beyond HTTP

| Resource | Status | Use |
|---|---|---|
| `HTTPRoute` | GA (v1.0) | HTTP/HTTPS routing |
| `GRPCRoute` | GA (v1.1) | gRPC service/method routing |
| `TLSRoute` | Standard (v1.5) | SNI-based TLS passthrough |
| `TCPRoute` | **GA (v1.6)** | Raw L4 TCP |
| `UDPRoute` | **GA (v1.6)** | Raw L4 UDP |

One API, one Gateway, one RBAC model — for everything entering the cluster.

**Compare:** ingress-nginx exposes TCP/UDP via a ConfigMap in `kube-system` listing `port: namespace/service:port`. No RBAC, no validation, no status.

---

<!-- _class: lab -->

# Lab 6 — GRPCRoute

**15 min** · podinfo already speaks gRPC on 9999. Route it with the same API.

1. Enable podinfo's gRPC port and mark the Service `appProtocol: kubernetes.io/h2c`
2. Write a `GRPCRoute` — matching on **service and method**, not on URL paths
3. Call it and confirm; then break the method match and read the status condition

```yaml
matches:
  - method:
      service: grpc.health.v1.Health
      method: Check
```

**Checkpoint:** one Gateway, one RBAC model, two protocols.
With Ingress this required a ConfigMap in `kube-system`.

---

# Portability, enforced

- Extensive **conformance test suite** maintained upstream
- Implementations publish signed **conformance reports** per release
- Conformance **profiles** (HTTP, GRPC, Mesh) with core vs extended feature sets

Practical consequence: an `HTTPRoute` using only core features behaves identically on Envoy Gateway, NGINX Gateway Fabric, Traefik, Cilium, Istio and Kong.

<span class="small">Check the reports before you commit to an implementation — "supports Gateway API" and "passes conformance for the features you use" are different claims.</span>

<!--
This is the single most useful practical tip in Part 2. Point people at the
implementations page and the conformance reports directory in the repo.
Extended features are where portability quietly stops.
-->

---

# Safe cross-namespace: `ReferenceGrant`

**Problem with Ingress:** an Ingress in namespace A referencing a Secret or Service elsewhere is either forbidden or unsafely permitted.

**Gateway API:** references across namespaces are denied by default, and the *target* namespace opts in.

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-infra-routes
  namespace: team-a          # namespace that OWNS the backend
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: shared-routes
  to:
    - group: ""
      kind: Service
      name: shop-api          # omit for all Services in this namespace
```

**The owner grants. The consumer cannot self-authorise.**

---

# Who may attach to my Gateway?

```yaml
listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.apps.example.com"
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
- Exactly the shared-ingress multi-tenancy problem that Rancher Projects create

---

<!-- _class: lab -->

# Lab 7 — Multi-tenancy and ReferenceGrant

**25 min** · The shared-Gateway model. Break it deliberately, then fix it.

1. Two tenant namespaces, one restricted Gateway (`from: Selector` + hostname pattern)
2. Label one namespace. Watch the other get `NotAllowedByListeners`.
3. **Attempt a hostname hijack** — find out what the spec does and does *not* protect
4. Cross-namespace `backendRef` → `RefNotPermitted`, fails closed and loud
5. The backend's owner adds a `ReferenceGrant`. It resolves.

**Checkpoint:** you can say who grants what, and where the remaining gap is.

<!--
Step 3 is the one to slow down on. Listener hostname constrains the suffix but
does NOT stop tenant B claiming tenant A's exact hostname — precedence is
deterministic but it is not an authorisation boundary. If you are delivering to
a customer designing a shared Gateway, this is the finding they will thank you
for. Mitigation is Kyverno or ValidatingAdmissionPolicy.
-->

---

# Mesh convergence (GAMMA)

Since v1.1, a `Service` can be a `parentRef`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments-internal
spec:
  parentRefs:
    - group: ""
      kind: Service         # east-west, not a Gateway
      name: payments
  rules:
    - backendRefs:
        - { name: payments-v1, port: 8080, weight: 80 }
        - { name: payments-v2, port: 8080, weight: 20 }
```

**Same API for north-south and east-west.** One mental model, one RBAC story, one set of skills.

---

# Ingress → Gateway API cheat sheet

| Ingress | Gateway API |
|---|---|
| `ingressClassName` | `GatewayClass` + `Gateway` |
| `spec.rules[].host` | Listener `hostname` and/or Route `hostnames` |
| `spec.rules[].http.paths[]` | `rules[].matches[].path` |
| `spec.tls[]` | Listener `tls.certificateRefs` |
| `rewrite-target` annotation | `URLRewrite` filter |
| `ssl-redirect` annotation | `RequestRedirect` filter on an HTTP listener |
| `canary-weight` annotation | `backendRefs[].weight` |
| `configuration-snippet` | Implementation policy CRD (deliberately not portable) |
| TCP/UDP ConfigMap | `TCPRoute` / `UDPRoute` |

---

# The honest downsides

- **More objects.** One Ingress becomes Gateway + Route, sometimes + ReferenceGrant.
- **Migration is real work.** No reliable automatic translator for annotation-heavy setups.
- **Policy is still the frontier.** `BackendTLSPolicy` is standard; auth, rate limiting, WAF and mTLS-to-backend remain **implementation-specific CRDs**. Portability stops there.
  - Concretely: Traefik plugs its own `Middleware` CRDs into an HTTPRoute as an `ExtensionRef` filter. The route is portable; the filter reference is not.
- **Ecosystem maturity gap.** cert-manager support is solid; ExternalDNS and some CI/CD tooling reached parity later.
- **Operational familiarity.** Your on-call knows how to debug ingress-nginx at 3am. That knowledge does not transfer for free.

<!--
Do not skip this slide. Credibility in the room depends on it, and if you are
delivering this to a customer it pre-empts the objection they were saving for
the end. The policy-attachment point is the genuinely unresolved one.
-->

---

# When to stay on Ingress

Gateway API is not automatically correct. Stay put if:

- Pure host/path routing, no annotations beyond TLS — **Ingress already does the job**
- Small team, no persona separation — the role model buys you nothing
- Ingress controller deeply wired into existing tooling with no migration budget
- Your platform's supported path has not caught up yet

**Migrate when you have a driver:** multi-tenancy, canary requirements, L4 routing, mesh convergence, or an RBAC problem you cannot solve today.

<span class="warn">On RKE2, ingress-nginx EOL is now that driver whether you wanted one or not.</span>

---

# The RKE2 picture just changed

**ingress-nginx went End-of-Life in March 2026.**

- Deprecated in RKE2 v1.36; no new images with fixes after March 2026
- **From v1.36, Traefik is the default ingress controller for new clusters**
- Rancher Prime customers get an extended support window — that is the commercial answer, not a technical one
- SUSE publishes an official **ingress-nginx → Traefik migration guide**

For your customers this is no longer "should we look at Gateway API someday."
It is **"we have to touch the ingress layer anyway."**

<span class="warn">That is the strongest migration driver in this deck, and it has a date on it.</span>

<!--
This slide reframes the whole session for a SUSE audience. Before March 2026 the
Gateway API conversation was strategic. Now there is a forced migration on the
table, and the question becomes "while we're in here, do we go to Gateway API
or just swap controllers?" That is a consulting conversation. Lead with it if
the room is customer-side.
-->

---

# RKE2 specifics

- Ingress controller is selected at server level:
  `ingress-controller: traefik | none` in `/etc/rancher/rke2/config.yaml`
- Tune with a **`HelmChartConfig`** named `rke2-traefik` in `kube-system` — never edit the
  Deployment directly, helm-controller reverts it
- **On RKE2, Gateway API means Traefik.** Enable it in the same HelmChartConfig:

```yaml
providers:
  kubernetesGateway:
    enabled: true
```

- Version pairing: **Traefik v3.7.x → Gateway API v1.5**, v3.6.x → v1.4
- Standard channel CRDs arrive with the `traefik-crds` AddOn.
  **Experimental channel must be installed separately** and enabled with `experimentalChannel: true`
- `--enable-servicelb` gives you ServiceLB (klipper-lb) so `LoadBalancer` Services work on bare VMs

---

# Two RKE2 gotchas worth writing down

**1. CRD deletion on rollback.**
Before the April 2026 releases (v1.33.11+rke2r1, v1.34.7+rke2r1, v1.35.4+rke2r1), disabling Traefik
after having enabled it **removes the Gateway API CRDs** — and with them every Gateway and Route
in the cluster.

<span class="warn">On an affected release, do not disable Traefik or uninstall `traefik-crds` while you have Gateway API resources you want to keep.</span>

**2. Traefik lags the spec.**
Traefik v3.7 tracks Gateway API v1.5 while upstream is at v1.6.1. So `TCPRoute` and `UDPRoute`
went GA upstream but are **not yet in your supported RKE2 path**.

**Consulting rule:** check the pairing table before you promise a customer a feature.

---

# Rancher

- Rancher's own management-server ingress still uses `Ingress` — Gateway API is for your workloads
- Rancher UI has no first-class Gateway API view; manage via `kubectl`, Fleet, or the CRD browser
- Rancher **Projects** map naturally onto the shared-Gateway model in Lab 4

<span class="small">Rancher's Gateway API tooling is moving. Re-check before every delivery.</span>

---

# Choosing an implementation

| Implementation | Status on RKE2 | Notes |
|---|---|---|
| **Traefik** | **Packaged & supported** | The RKE2 answer. Default controller from v1.36. One HelmChartConfig away. |
| Cilium | Viable | Only if Cilium is already your CNI. Never change CNI for this. |
| Istio | Viable | Right call when you want mesh + ingress on one API. Heavier. |
| Envoy Gateway | Bring-your-own | Pure Gateway API, excellent status conditions. **Not** SUSE-packaged. |
| NGINX Gateway Fabric | Bring-your-own | Different project from the EOL ingress-nginx. Not SUSE-packaged. |

**We use Traefik in the labs** — because on RKE2 it is one config flag, and because it is what your
customer will actually run in production.

<!--
Be straight with the room about this. Envoy Gateway is arguably the nicer
teaching vehicle — its status conditions are more verbose and its per-Gateway
infrastructure provisioning makes the model more obvious. But shipping a SUSE
training that demos an unsupported implementation creates a support conversation
you do not want. Teach the supported path; mention the others exist.
-->

---

# One architectural difference worth knowing

**Traefik: static infrastructure.**
One Traefik deployment. Gateway listeners bind to pre-existing **entryPoints** (`web`, `websecure`).
A listener on a port with no matching entryPoint does not become `Programmed`.

**Envoy Gateway, NGF: dynamic provisioning.**
Each `Gateway` gets its own deployment and Service, provisioned on demand.

This is not a defect in either. It is a real design split across conformant implementations, and it
changes how you plan capacity, isolation, and blast radius.

<span class="warn">Portable manifests do not mean identical operations.</span>

---

# Migration strategy that works

**On RKE2 today this is two migrations, not one. Do not conflate them.**

1. **Controller swap** — ingress-nginx → Traefik, `Ingress` objects unchanged.
   Follow SUSE's migration guide. This is forced work with a deadline.
2. **API migration** — `Ingress` → `HTTPRoute`, controller unchanged.
   This is optional, per-app, and on your schedule.

For step 2:

- **Run in parallel.** Ingress and HTTPRoute can serve the same app on the same Traefik.
- **Translate one app.** Non-critical, annotation-light. Prove the pattern.
- **Compare behaviour** — status codes, headers, redirects. Do not assume equivalence.
- **Shift at the edge** — DNS or external LB. Rollback is a DNS change.
- **Keep the Ingress object** until you have soaked in production.

<span class="small">Lab 2 is step 2, on a single VM.</span>

---

<!-- _class: lead -->

# Wrap-up

## What to take back to your cluster

---

# Decision checklist

**Do you have a Gateway API driver?**

- Multiple teams sharing one entry point → **yes**
- Canary / progressive delivery without a mesh → **yes**
- TCP, UDP, or gRPC routing → **yes**
- Mesh and ingress on one API → **yes**
- Host/path routing that already works → **not yet**

**If yes:** pick an implementation, check its conformance report for the features you actually use, run it in parallel, migrate one app.

---

# Resources

**Start here (RKE2)**
- RKE2 networking services — `docs.rke2.io/networking/networking_services#gateway-api`
- ingress-nginx → Traefik migration — `docs.rke2.io/reference/ingress_migration`
- Traefik Gateway provider — `doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/`
- Traefik Gateway routing — `doc.traefik.io/traefik/reference/routing-configuration/kubernetes/gateway-api/`

**Upstream**
- `gateway-api.sigs.k8s.io` — spec, concepts, security model
- `gateway-api.sigs.k8s.io/implementations/` — conformance reports. Read these before you recommend.
- `#sig-network-gateway-api` on Kubernetes Slack

**Other implementations**
- Envoy Gateway — `gateway.envoyproxy.io` · NGINX Gateway Fabric — `docs.nginx.com/nginx-gateway-fabric/`

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Questions

**Florian Coulombel**
SUSE Consulting — Lead Architect

<!--
Reserve at least 15 minutes. The three questions that always come:
1. "Is Ingress deprecated?" — No. Frozen, not deprecated.
2. "Which implementation should we pick?" — On RKE2, Traefik. It is packaged
   and supported. Only go bring-your-own if there is a concrete feature gap,
   and be explicit about the support consequences.
3. "How do we do auth / rate limiting / WAF?" — Implementation-specific CRDs
   today. Be honest that this is where portability currently stops.
-->
