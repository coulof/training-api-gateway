# Gateway API on RKE2 with Traefik — Lab Manual

**Half-day workshop · one single-node RKE2 VM per participant**

---

## How this works

Seven labs, interleaved with the slides. Each one appears immediately after the concept it proves.

We configure **one application — podinfo — twice**: first the Ingress way (Labs 1–2), then the
Gateway API way (Labs 4–7). Everything lives in `~/lab/` under **git**, so at the end you can
`git diff` the two eras against each other. That diff is the point of the day.

| Lab | After slide | Topic | Time |
|---|---|---|---|
| 1 | *What Ingress gave us* | Bootstrap, own the YAML, verify ServiceLB | 20 min |
| 2 | *The annotation explosion* | Rewrite + canary + the RBAC problem | 25 min |
| 3 | *The resource model* | Enable Gateway API, verify CRDs, GatewayClass | 10 min |
| 4 | *Status conditions* | Gateway + HTTPRoute, personas, RBAC done right | 25 min |
| 5 | *Traffic splitting* | Canary with weights, header routing | 20 min |
| 6 | *Beyond HTTP* | GRPCRoute | 15 min |
| 7 | *Who may attach* | Multi-tenancy + ReferenceGrant | 25 min |

> ### ⚠ Verification status
>
> Gateway API manifests here are spec-standard and portable. **Traefik- and RKE2-specific
> behaviours** — entryPoint binding, GatewayClass naming, exact status reasons, gRPC h2c handling —
> were written from documentation, not a live run. Steps marked **⚠ VERIFY** must be executed on a
> real VM before delivery. Where reality differs, reality wins — fix the manual.
>
> `./scripts/40-validate-lab.sh --answers` resolves most of these against a live cluster.

**Golden rule:** when something breaks, `kubectl describe` the Route and the Gateway **before**
reading any logs. The status conditions almost always tell you the answer.

---

## Access model

**You drive the lab entirely through a kubeconfig from your own machine.** No SSH, no root, no node
access. Your instructor hands you a kubeconfig file; everything in this manual works from there.

```bash
export KUBECONFIG=./gwapi-lab.kubeconfig
kubectl config current-context
kubectl get nodes
```

Run the prerequisite check before Lab 1 — it verifies your tooling, your RBAC, and that Traefik is
serving:

```bash
./scripts/00-check-prereqs.sh
```

### Reaching the Gateway

Every lab sends HTTP through Traefik with a `Host` header. You need one reachable URL in `$GW_URL`.

**Option A — Traefik's LoadBalancer address**, if it is routable from your machine:

```bash
export GW_URL="http://$(kubectl -n kube-system get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl -s -o /dev/null -w '%{http_code}\n' "$GW_URL/"      # expect 404
```

**Option B — port-forward.** Works from anywhere a kubeconfig works, including behind VPN or NAT.
Leave it running in a second terminal:

```bash
kubectl -n kube-system port-forward svc/traefik 8080:80
```

```bash
export GW_URL="http://127.0.0.1:8080"
```

`404` is the correct answer either way: Traefik is listening, nothing is routed yet. **If you get a
connection refused, stop and fix it now** — every later lab depends on this path.

> Option A exercises the real data path and is preferable when it works. Option B is the reliable
> fallback and is what the scripts choose automatically.

### Your working directory

Labs 1–7 build up YAML that **you own**, on **your machine**, tracked in git:

```bash
mkdir -p ~/lab && cd ~/lab
```

---

# Lab 1 — Make it work, the 2015 way

**20 min** · *After: "What Ingress gave us"*

**Objective:** a working Ingress, proof that ServiceLB is doing its job, and ownership of the YAML
we will edit all session.

## 1.1 — Verify the cluster

```bash
kubectl get nodes
kubectl -n kube-system get pods | grep traefik
kubectl get ingressclass
```

Now the important one — **ServiceLB**:

```bash
kubectl -n kube-system get svc traefik
```

`EXTERNAL-IP` must show an address, **not `<pending>`**. That is klipper-lb, enabled with
`enable-servicelb: true`, claiming host ports 80 and 443 on the node.

And confirm the entryPoints the Gateway listeners will later bind to:

```bash
kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.name}:{.port}{"\n"}{end}'
```

You should have `web:80` and `websecure:443`. **⚠ VERIFY** — Lab 4 assumes these names.

Confirm `$GW_URL` is set and answering (see **Access model** above):

```bash
curl -s -o /dev/null -w '%{http_code}\n' $GW_URL/
```

## 1.2 — Look at what podinfo's chart generates

We are not going to *use* the chart. We are going to read it, then take what we need.

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
```

**⚠ VERIFY** the repo is reachable from the lab network.

```bash
mkdir -p ~/lab && cd ~/lab

helm template podinfo podinfo/podinfo \
  --set ingress.enabled=true \
  --set ingress.className=traefik \
  --set 'ingress.hosts[0].host=podinfo.lab' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  > generated-by-helm.yaml

grep -c '^---' generated-by-helm.yaml
less generated-by-helm.yaml
```

**Read it.** Note how much of it is chart plumbing — labels, checksums, conditionals — and how
little is the actual routing decision.

**Discussion:** the chart's `ingress.yaml` template is a few dozen lines of Go templating wrapping
about eight lines of real configuration. That ratio is a hint about how much accidental complexity
the Ingress API pushed onto chart authors.

## 1.3 — Take ownership

From here on you maintain the YAML, not Helm. This is deliberate: you cannot see an API's
ergonomics through a templating layer.

```bash
cd ~/lab
```

```bash
cat > 01-podinfo-v1.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-v1
  namespace: demo
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
          image: ghcr.io/stefanprodan/podinfo:6.7.0
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
  namespace: demo
spec:
  selector: { app: podinfo, version: v1 }
  ports:
    - { name: http, port: 9898, targetPort: http }
EOF
```

```bash
cat > 02-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: podinfo
  namespace: demo
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
EOF
```

```bash
kubectl apply -f 01-podinfo-v1.yaml -f 02-ingress.yaml
kubectl -n demo rollout status deploy/podinfo-v1
```

## 1.4 — Start tracking changes

```bash
cd ~/lab
git init -q
printf 'generated-by-helm.yaml\n' > .gitignore
git add -A && git commit -qm "Lab 1: podinfo behind a plain Ingress"
git log --oneline
```

Every later lab ends with a commit. At the end of the day, `git diff` between two commits is your
Ingress-vs-Gateway-API comparison — no slides required.

## 1.5 — Prove it works

```bash
curl -s -H 'Host: podinfo.lab' $GW_URL/ | jq -r '.hostname, .message, .version'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: wrong.lab' $GW_URL/
```

`VERSION ONE` and then `404`.

## Checkpoint

- ServiceLB has given Traefik a real address
- podinfo is reachable through a plain Ingress
- The YAML is yours, in git

**Discussion:** everything on this slide's worth of YAML is portable across ingress controllers.
Note that, because it is the last time today it will be true without effort.

---

# Lab 2 — Live the annotation problem

**25 min** · *After: "The annotation explosion"*

**Objective:** perform the two most common real-world routing tasks and feel what they cost.

## 2.1 — Task one: serve the app under a path prefix

Requirement: `podinfo.lab/shop/*` should reach podinfo, which knows nothing about `/shop`.

On Traefik this needs a **vendor CRD**, an **annotation**, and a **naming convention**:

```bash
cd ~/lab
cat > 03-middleware-strip.yaml <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-shop
  namespace: demo
spec:
  stripPrefix:
    prefixes:
      - /shop
EOF
```

```bash
cat > 02-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: podinfo
  namespace: demo
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: demo-strip-shop@kubernetescrd
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: podinfo.lab
      http:
        paths:
          - path: /shop
            pathType: Prefix
            backend:
              service:
                name: podinfo-v1
                port:
                  number: 9898
EOF

kubectl apply -f 03-middleware-strip.yaml -f 02-ingress.yaml
curl -s -H 'Host: podinfo.lab' $GW_URL/shop/version | jq -r .version
```

**Now break it on purpose.** Change the annotation value to `strip-shop` (drop the namespace prefix
and the `@kubernetescrd` provider suffix):

```bash
kubectl -n demo annotate ingress podinfo \
  traefik.ingress.kubernetes.io/router.middlewares=strip-shop --overwrite
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: podinfo.lab' $GW_URL/shop/version
```

**⚠ VERIFY** the exact failure mode. Expect a silent 404 or 500 — **no admission error, no event on
the Ingress**. The annotation is an opaque string; nothing validated it.

Restore it:

```bash
kubectl apply -f 02-ingress.yaml
```

**Discussion:** three separate things had to be right — CRD name, namespace prefix, provider suffix
— and none of them is described anywhere in the Kubernetes API. `kubectl explain ingress` will never
tell you about `@kubernetescrd`.

## 2.2 — Task two: canary 10% to v2

Deploy v2:

```bash
cd ~/lab
cat > 04-podinfo-v2.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-v2
  namespace: demo
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
          image: ghcr.io/stefanprodan/podinfo:6.7.0
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
  namespace: demo
spec:
  selector: { app: podinfo, version: v2 }
  ports:
    - { name: http, port: 9898, targetPort: http }
EOF

kubectl apply -f 04-podinfo-v2.yaml
kubectl -n demo rollout status deploy/podinfo-v2
```

Now the canary. **There is no field for this.** You create a *second, duplicate Ingress object*:

```bash
cat > 05-ingress-canary.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: podinfo-canary
  namespace: demo
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: demo-strip-shop@kubernetescrd
    traefik.ingress.kubernetes.io/router.entrypoints: web
    # weighting on Ingress is implementation-specific and NOT portable
    traefik.ingress.kubernetes.io/service.weight: "10%"
spec:
  ingressClassName: traefik
  rules:
    - host: podinfo.lab
      http:
        paths:
          - path: /shop
            pathType: Prefix
            backend:
              service:
                name: podinfo-v2
                port:
                  number: 9898
EOF

kubectl apply -f 05-ingress-canary.yaml
```

Measure it:

```bash
for i in $(seq 1 100); do
  curl -s -H 'Host: podinfo.lab' $GW_URL/shop/ | jq -r .message
done | sort | uniq -c
```

> **⚠ VERIFY — this step is expected to be unsatisfying.**
> Traefik's weighted routing is designed around its own `TraefikService` CRD, not around Ingress
> annotations. You may see a 50/50 split, or all-v1, rather than 90/10.
>
> **If it does not weight correctly, that is the lesson, not a lab bug.** Record what you observe.
> The teaching point stands either way: there is no portable, typed way to express "10% of traffic"
> in the Ingress API, and each controller invented something different — ingress-nginx used
> `canary-weight` on a duplicate object, Traefik pushes you to a `TraefikService` CRD.
>
> If you want a working weighted split on Ingress for the demo, do it with a `TraefikService` and
> reference it from the Ingress — and notice that you have now left the Kubernetes API entirely.

## 2.3 — Task three: the RBAC problem

Create a Role that lets an application developer manage their own routing:

```bash
cd ~/lab
cat > 06-rbac-ingress.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev
  namespace: demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingress-editor
  namespace: demo
rules:
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-ingress-editor
  namespace: demo
subjects:
  - kind: ServiceAccount
    name: dev
    namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-editor
EOF

kubectl apply -f 06-rbac-ingress.yaml
```

Now act as that developer:

```bash
DEV="--as=system:serviceaccount:demo:dev"

# Intended: change your own path. Fine.
kubectl $DEV -n demo auth can-i update ingress

# Not intended: change the hostname you serve on
kubectl $DEV -n demo patch ingress podinfo --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/host","value":"api.corp.example.com"}]'
```

That succeeded. A developer just claimed a hostname belonging to someone else.

```bash
# Not intended: attach a TLS certificate reference
kubectl $DEV -n demo patch ingress podinfo --type=merge \
  -p '{"spec":{"tls":[{"hosts":["api.corp.example.com"],"secretName":"corp-wildcard"}]}}'
```

Also succeeded.

Restore:

```bash
kubectl apply -f 02-ingress.yaml
```

**Discussion — this is the structural argument, made concrete.** RBAC is
`verb × resource × namespace`. Hostname, TLS, and path all live in *one resource*, so any Role that
permits a developer to change a path also permits them to change TLS and hostname.

Ask the room how they handle this today. The answer is almost always "the platform team owns
Ingress and we raise a ticket." That ticket queue is a consequence of API design.

## 2.4 — Commit the Ingress era

```bash
cd ~/lab
git add -A && git commit -qm "Lab 2: prefix rewrite, canary attempt, and RBAC on Ingress"
git log --oneline
```

## Checkpoint

You should be able to name three concrete problems:

1. Configuration in **untyped annotations** with a naming convention outside the API — fails silently
2. Traffic weighting has **no portable expression** — every controller invented its own
3. **One resource, three personas** — RBAC cannot separate path from TLS from hostname

Hold on to these. Labs 4 and 5 fix all three.

---

# Lab 3 — Turn on Gateway API

**10 min** · *After: "The resource model"*

**Objective:** install capability. Nothing routes yet.

## 3.1 — Check what exists first

```bash
kubectl get crd | grep gateway.networking.k8s.io || echo "no Gateway API CRDs"
kubectl get gatewayclass 2>/dev/null || echo "no GatewayClass"
```

**⚠ VERIFY:** on some RKE2 versions the `traefik-crds` AddOn installs the Standard-channel CRDs even
with the Gateway provider disabled. Note which case you are in.

## 3.2 — Enable the provider

An **operator** action, via RKE2's packaged-component mechanism. Never `kubectl edit deploy/traefik`
— helm-controller reverts it.

A `HelmChartConfig` is an ordinary namespaced custom resource, so `kubectl apply` works:

```bash
cd ~/lab
cat > 09-helmchartconfig-traefik.yaml <<'EOF'
---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
EOF

kubectl apply -f 09-helmchartconfig-traefik.yaml
kubectl -n kube-system rollout status deploy/traefik --timeout=5m
```

> **Why not the manifests directory?** RKE2 also reads packaged-component config from
> `/var/lib/rancher/rke2/server/manifests/` on the node. That works, but it needs filesystem access
> to a control-plane node. `kubectl apply` achieves the same thing over a kubeconfig — which is why
> this lab uses it, and why it is the better habit for GitOps.

If the rollout stalls, inspect the helm-controller's work:

```bash
kubectl -n kube-system get helmchart,helmchartconfig
kubectl -n kube-system get jobs -l helmcharts.helm.cattle.io/chart=rke2-traefik
```

> **⚠ Production warning — CRD deletion on rollback.**
> Before the April 2026 releases (v1.33.11+rke2r1, v1.34.7+rke2r1, v1.35.4+rke2r1), **disabling
> Traefik after having enabled it removes the Gateway API CRDs** — and every Gateway and Route with
> them. Do not disable Traefik or uninstall `traefik-crds` while you have resources you care about.
>
> `kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}{"\n"}'`

## 3.3 — Verify the CRDs

```bash
kubectl get crd | grep gateway.networking.k8s.io

kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'

kubectl api-resources --api-group=gateway.networking.k8s.io
```

Which Route kinds do you have? Which versions are served?

```bash
kubectl explain httproute.spec.rules.matches.headers
```

**This command is the whole argument.** It works because the field is typed. No annotation was ever
discoverable this way.

## 3.4 — The GatewayClass you did not create

```bash
kubectl get gatewayclass
kubectl describe gatewayclass
```

```bash
export GWCLASS=$(kubectl get gatewayclass -o jsonpath='{.items[0].metadata.name}')
echo "GatewayClass: $GWCLASS"
```

**⚠ VERIFY** the name — later labs use `${GWCLASS:-traefik}`.

`ACCEPTED=True` means Traefik saw a class naming its `controllerName` and claimed it.

## 3.5 — Version reality check

```bash
kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Pairing: **Traefik v3.7.x → Gateway API v1.5**, v3.6.x → v1.4. Upstream is at v1.6.1.

**Discussion:** `TCPRoute` and `UDPRoute` went GA upstream in v1.6 — they are **not** in your
supported path yet. Check this pairing before promising a customer a feature.

## Checkpoint

- CRDs present, version known
- A `GatewayClass` exists that you did not author — infrastructure declared its capability
- Zero routing changed. Capability and configuration are separate acts.

---

# Lab 4 — Gateway + HTTPRoute

**25 min** · *After: "Status conditions"*

**Objective:** same app, same rewrite as Lab 2 — with the personas actually separated.

## 4.1 — Operator: create the Gateway

```bash
kubectl create namespace infra
cd ~/lab
```

```bash
cat > 10-gateway.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: infra
spec:
  gatewayClassName: ${GWCLASS:-traefik}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF

kubectl apply -f 10-gateway.yaml
kubectl -n infra get gateway web -w      # wait for PROGRAMMED=True, Ctrl-C
kubectl -n infra describe gateway web
```

Read both conditions: `Accepted` (spec valid, this controller owns it) and `Programmed` (data plane
actually configured).

**Note:** port 80 works because it maps to Traefik's existing `web` **entryPoint**. On Traefik a
listener binds to fixed infrastructure — it does not create one.

**⚠ VERIFY** entryPoint names: `kubectl -n kube-system get svc traefik -o jsonpath='{.spec.ports}' | jq`

## 4.2 — Developer: create the HTTPRoute, and get rejected

```bash
cat > 11-httproute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
  namespace: demo
spec:
  parentRefs:
    - { name: web, namespace: infra, sectionName: http }
  hostnames:
    - gw.podinfo.lab
  rules:
    - matches:
        - path: { type: PathPrefix, value: /shop }
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - { name: podinfo-v1, port: 9898 }
EOF

kubectl apply -f 11-httproute.yaml
kubectl -n demo describe httproute podinfo
```

**Expect `Accepted: False`, reason `NotAllowedByListeners`.**

The listener says `from: Same` — only routes in `infra` may attach. The route is in `demo`.

**This is the model working.** Compare with Lab 2, where a developer could silently claim
`api.corp.example.com`.

## 4.3 — Operator opens the listener

```bash
cd ~/lab
sed -i 's/from: Same/from: All/' 10-gateway.yaml
kubectl apply -f 10-gateway.yaml
kubectl -n demo describe httproute podinfo
```

Now `Accepted: True` and `ResolvedRefs: True`.

```bash
curl -s -H 'Host: gw.podinfo.lab' $GW_URL/shop/version | jq -r .version
curl -s -H 'Host: gw.podinfo.lab' $GW_URL/shop/ | jq -r .message
```

## 4.4 — Compare with Lab 2

The rewrite that needed a CRD, an annotation and a naming convention is now:

```yaml
filters:
  - type: URLRewrite
    urlRewrite:
      path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
```

Typed. Validated at admission. Discoverable:

```bash
kubectl explain httproute.spec.rules.filters.urlRewrite
```

Break it on purpose, the way you broke the annotation in Lab 2:

```bash
kubectl -n demo patch httproute podinfo --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/filters/0/urlRewrite/path/type","value":"Nonsense"}]'
```

**Rejected at admission** with a message naming the valid values. In Lab 2 the equivalent mistake
returned a silent 404.

## 4.5 — RBAC, done right

```bash
cd ~/lab
cat > 12-rbac-gateway.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: route-editor
  namespace: demo
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes", "grpcroutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-route-editor
  namespace: demo
subjects:
  - kind: ServiceAccount
    name: dev
    namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: route-editor
EOF

kubectl apply -f 12-rbac-gateway.yaml
```

```bash
DEV="--as=system:serviceaccount:demo:dev"

kubectl $DEV -n demo auth can-i update httproutes.gateway.networking.k8s.io   # yes
kubectl $DEV -n infra auth can-i update gateways.gateway.networking.k8s.io    # no
kubectl $DEV -n infra auth can-i get secrets                                 # no
```

The developer can change any routing rule they like and **cannot touch listeners, TLS, or the
Gateway**. That is the boundary Lab 2.3 could not express.

## 4.6 — Commit

```bash
cd ~/lab
git add -A && git commit -qm "Lab 4: Gateway + HTTPRoute, typed rewrite, scoped RBAC"
```

## Checkpoint

Three of the Lab 2 problems, addressed:

| Lab 2 problem | Lab 4 answer |
|---|---|
| Untyped annotation, silent failure | Typed filter, admission-rejected |
| One resource, three personas | Gateway (operator) vs HTTPRoute (developer) |
| No discoverability | `kubectl explain` works |

Weighting is next.

---

# Lab 5 — Canary, properly

**20 min** · *After: "Expressiveness — traffic splitting"*

**Objective:** the Lab 2.2 task again. Compare the mechanism.

## 5.1 — Weights in one object

```bash
cd ~/lab
cat > 11-httproute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
  namespace: demo
spec:
  parentRefs:
    - { name: web, namespace: infra, sectionName: http }
  hostnames:
    - gw.podinfo.lab
  rules:
    - matches:
        - path: { type: PathPrefix, value: /shop }
      filters:
        - type: URLRewrite
          urlRewrite:
            path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
      backendRefs:
        - { name: podinfo-v1, port: 9898, weight: 90 }
        - { name: podinfo-v2, port: 9898, weight: 10 }
EOF

kubectl apply -f 11-httproute.yaml
```

```bash
for i in $(seq 1 100); do
  curl -s -H 'Host: gw.podinfo.lab' $GW_URL/shop/ | jq -r .message
done | sort | uniq -c
```

**No second object. No CRD. No annotation.** Compare against what you measured in Lab 2.2.

## 5.2 — Shift the weights

```bash
kubectl -n demo patch httproute podinfo --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
       {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}]'
```

Re-measure. Then go to 0/100 and re-measure again.

**Discussion:** this is a field on one object, which is exactly why Argo Rollouts and Flagger can
drive it. A controller that had to create and delete duplicate Ingress objects — and get vendor
annotations right — is a much harder controller to write and trust.

## 5.3 — Deterministic targeting

Weights are for gradual exposure. Headers are for "QA always gets v2".

**Order matters** — more specific rules first.

```bash
cd ~/lab
cat > 11-httproute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
  namespace: demo
spec:
  parentRefs:
    - { name: web, namespace: infra, sectionName: http }
  hostnames:
    - gw.podinfo.lab
  rules:
    # Rule 1 — opt-in testers always reach v2
    - matches:
        - path: { type: PathPrefix, value: /shop }
          headers:
            - { name: x-canary, type: Exact, value: "true" }
      filters:
        - type: URLRewrite
          urlRewrite:
            path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - { name: x-served-by, value: canary }
      backendRefs:
        - { name: podinfo-v2, port: 9898 }
    # Rule 2 — everyone else, 95/5
    - matches:
        - path: { type: PathPrefix, value: /shop }
      filters:
        - type: URLRewrite
          urlRewrite:
            path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - { name: x-served-by, value: stable }
      backendRefs:
        - { name: podinfo-v1, port: 9898, weight: 95 }
        - { name: podinfo-v2, port: 9898, weight: 5 }
EOF

kubectl apply -f 11-httproute.yaml
```

```bash
curl -s  -H 'Host: gw.podinfo.lab' -H 'x-canary: true' $GW_URL/shop/ | jq -r .message
curl -si -H 'Host: gw.podinfo.lab' -H 'x-canary: true' $GW_URL/shop/ | grep -i x-served-by

for i in $(seq 1 40); do
  curl -s -H 'Host: gw.podinfo.lab' $GW_URL/shop/ | jq -r .message
done | sort | uniq -c
```

## 5.4 — The diff

```bash
cd ~/lab
git add -A && git commit -qm "Lab 5: weighted canary and header routing in one HTTPRoute"

# Ingress era vs Gateway API era
git log --oneline
git diff HEAD~3 HEAD -- . | head -80
```

**Show this to the room.** Two Ingress objects plus a Middleware CRD plus five annotations became
one HTTPRoute.

## Checkpoint

- Weights are a typed field, not a duplicate object
- Header matching gives deterministic targeting
- Filters compose per-rule

---

# Lab 6 — GRPCRoute

**15 min** · *After: "Beyond HTTP"*

**Objective:** route a second protocol through the same Gateway with the same RBAC.

podinfo already serves gRPC — it just needs enabling.

## 6.1 — Turn on podinfo's gRPC port

```bash
cd ~/lab
cat > 20-podinfo-grpc.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-grpc
  namespace: demo
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
          image: ghcr.io/stefanprodan/podinfo:6.7.0
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
  namespace: demo
spec:
  selector: { app: podinfo, proto: grpc }
  ports:
    - name: grpc
      port: 9999
      targetPort: grpc
      appProtocol: kubernetes.io/h2c
EOF

kubectl apply -f 20-podinfo-grpc.yaml
kubectl -n demo rollout status deploy/podinfo-grpc
```

**⚠ VERIFY** — `appProtocol: kubernetes.io/h2c` is how Gateway API signals cleartext HTTP/2 to the
backend. Confirm Traefik honours it; without it you will likely get a protocol error rather than a
routing error.

## 6.2 — The GRPCRoute

Note what it matches on: **service and method**, not URL paths.

```bash
cat > 21-grpcroute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: podinfo-grpc
  namespace: demo
spec:
  parentRefs:
    - { name: web, namespace: infra, sectionName: http }
  hostnames:
    - grpc.podinfo.lab
  rules:
    - matches:
        - method:
            service: grpc.health.v1.Health
            method: Check
      backendRefs:
        - { name: podinfo-grpc, port: 9999 }
EOF

kubectl apply -f 21-grpcroute.yaml
kubectl -n demo describe grpcroute podinfo-grpc
```

Confirm `Accepted: True` and `ResolvedRefs: True`.

## 6.3 — Call it

```bash
grpcurl -plaintext -authority grpc.podinfo.lab \
  ${GW_URL#http://} grpc.health.v1.Health/Check
```

**⚠ VERIFY** — if `grpcurl` is not on the VM, run it from a pod:

```bash
kubectl run grpcurl --rm -it --restart=Never \
  --image=fullstorydev/grpcurl:latest -- \
  -plaintext -authority grpc.podinfo.lab \
  ${GW_URL#http://} grpc.health.v1.Health/Check
```

## 6.4 — Break the method match

```bash
kubectl -n demo patch grpcroute podinfo-grpc --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/matches/0/method/method","value":"Watch"}]'
```

Re-run the `Check` call. It should no longer route. Read the conditions — the route is still
`Accepted`, it simply does not match. **⚠ VERIFY** the gRPC status code returned.

Restore:

```bash
kubectl apply -f 21-grpcroute.yaml
cd ~/lab && git add -A && git commit -qm "Lab 6: GRPCRoute on the same Gateway"
```

## Checkpoint

- **One Gateway, one RBAC model, two protocols**
- The developer Role from Lab 4.5 already covered `grpcroutes` — no new permission grant
- Compare: exposing gRPC or TCP through ingress-nginx meant a ConfigMap in `kube-system`, with no
  RBAC, no validation, and no status

**Discussion:** `TCPRoute` and `UDPRoute` went GA upstream in v1.6 but are not in Traefik's
Gateway API v1.5 support. What would you tell a customer who needs raw TCP today?

---

# Lab 7 — Multi-tenancy and ReferenceGrant

**25 min** · *After: "Who may attach to my Gateway?"*

**Objective:** the shared-Gateway model. Break it deliberately, then fix it.

Maps directly onto Rancher Projects.

## 7.1 — Two tenants

```bash
kubectl create namespace team-a
kubectl create namespace team-b

for t in a b; do
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: team-$t
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
          image: ghcr.io/stefanprodan/podinfo:6.7.0
          ports:
            - { name: http, containerPort: 9898 }
          env:
            - { name: PODINFO_UI_MESSAGE, value: "TEAM ${t^^}" }
---
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: team-$t
spec:
  selector: { app: app }
  ports:
    - { name: http, port: 9898, targetPort: http }
EOF
done
```

## 7.2 — A restricted shared Gateway

```bash
cd ~/lab
cat > 30-gateway-shared.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared
  namespace: infra
spec:
  gatewayClassName: ${GWCLASS:-traefik}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.tenants.lab"
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
        kinds:
          - kind: HTTPRoute
EOF

kubectl apply -f 30-gateway-shared.yaml
kubectl -n infra wait --for=condition=Programmed gateway/shared --timeout=2m
```

Three controls in one listener: **which namespaces**, **which route kinds**, **which hostnames**.

This Gateway reuses the same `web` entryPoint — on Traefik a second Gateway is a second *view* onto
shared infrastructure, not a second data plane.

## 7.3 — Selective access

```bash
kubectl label namespace team-a gateway-access=true

for t in a b; do
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app
  namespace: team-$t
spec:
  parentRefs:
    - { name: shared, namespace: infra, sectionName: http }
  hostnames:
    - team-$t.tenants.lab
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - { name: app, port: 9898 }
EOF
done
```

```bash
kubectl -n team-a get httproute app -o jsonpath='{.status.parents[0].conditions}' | jq
kubectl -n team-b get httproute app -o jsonpath='{.status.parents[0].conditions}' | jq

curl -s -H 'Host: team-a.tenants.lab' $GW_URL/ | jq -r .message
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: team-b.tenants.lab' $GW_URL/
```

Team A: `Accepted: True`. Team B: `Accepted: False` / `NotAllowedByListeners`.

Grant access — an operator action on the **namespace**, not on the tenant's route:

```bash
kubectl label namespace team-b gateway-access=true
sleep 5
curl -s -H 'Host: team-b.tenants.lab' $GW_URL/ | jq -r .message
```

## 7.4 — Hostname hijack attempt

```bash
kubectl -n team-b patch httproute app --type=merge \
  -p '{"spec":{"hostnames":["team-a.tenants.lab","evil.example.com"]}}'

kubectl -n team-b get httproute app -o jsonpath='{.status.parents[0].conditions}' | jq

for i in $(seq 1 10); do
  curl -s -H 'Host: team-a.tenants.lab' $GW_URL/ | jq -r .message
done | sort | uniq -c
```

`evil.example.com` does not intersect `*.tenants.lab` and is dropped from the effective hostname set.

`team-a.tenants.lab` is a real conflict between two tenants.

**Discussion — the finding worth taking to a customer.** Listener `hostname` constrains the
*suffix*, but it does not stop tenant B declaring tenant A's exact hostname. Conflict resolution
follows spec precedence (oldest wins for equal specificity) — deterministic, but **not an
authorisation boundary**.

Enforce ownership with admission policy: Kyverno or a `ValidatingAdmissionPolicy` asserting each
namespace may only claim hostnames matching its own prefix.

```bash
kubectl -n team-b patch httproute app --type=merge \
  -p '{"spec":{"hostnames":["team-b.tenants.lab"]}}'
```

## 7.5 — Cross-namespace backend, denied

```bash
kubectl -n team-a patch httproute app --type=json -p '[
  {"op":"add","path":"/spec/rules/0/backendRefs/-",
   "value":{"name":"app","namespace":"team-b","port":9898,"weight":50}}
]'

kubectl -n team-a get httproute app -o jsonpath='{.status.parents[0].conditions}' | jq
```

`ResolvedRefs: False`, reason **`RefNotPermitted`**.

```bash
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: team-a.tenants.lab' $GW_URL/
done | sort | uniq -c
```

Fails **closed and loud** — it does not silently route. **⚠ VERIFY** the exact status code.

## 7.6 — The owner grants permission

The grant lives in the namespace that **owns the backend**. Team A cannot create it.

```bash
cd ~/lab
cat > 31-referencegrant.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-team-a
  namespace: team-b
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: team-a
  to:
    - group: ""
      kind: Service
      name: app
EOF

kubectl apply -f 31-referencegrant.yaml
```

> **Version note.** `ReferenceGrant` was promoted in Gateway API v1.5, which Traefik v3.7 tracks.
> `kubectl api-resources | grep referencegrant` — use `v1beta1` if `v1` is not served.

```bash
kubectl -n team-a get httproute app -o jsonpath='{.status.parents[0].conditions}' | jq

for i in $(seq 1 20); do
  curl -s -H 'Host: team-a.tenants.lab' $GW_URL/ | jq -r .message
done | sort | uniq -c
```

`ResolvedRefs: True`, traffic splits between `TEAM A` and `TEAM B`.

```bash
cd ~/lab && git add -A && git commit -qm "Lab 7: shared Gateway, tenant isolation, ReferenceGrant"
```

## Checkpoint

- Namespace **label** controls who may attach
- `ReferenceGrant` controls who may be a **backend**, granted by the owner
- Listener hostname is a suffix constraint, **not** an ownership boundary — add admission policy
- Every denial appears in status with a specific, spec-defined reason

**Discussion:** map this onto Rancher. A Project spans namespaces. Where does the Gateway live? Who
holds edit rights on namespace labels? What does the platform team keep, and what does the Project
owner get?

---

# The session in one command

```bash
cd ~/lab
git log --oneline
git diff $(git log --format=%H | tail -1) HEAD --stat
```

Ingress era: 2 Ingress objects, 1 Middleware CRD, 5 annotations, 1 unusable RBAC Role.
Gateway API era: 1 Gateway, 1 HTTPRoute, 1 GRPCRoute, 1 scoped RBAC Role — plus multi-tenancy that
was not achievable before.

---

# Appendix A — TLS (bonus, ~20 min)

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=gw.podinfo.lab" -addext "subjectAltName=DNS:gw.podinfo.lab"

kubectl -n infra create secret tls podinfo-tls --cert=/tmp/tls.crt --key=/tmp/tls.key
```

The certificate lives in the **operator's** namespace. Developers never see it — and per Lab 4.5,
cannot read it.

```bash
cd ~/lab
cat > 40-gateway-tls.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: infra
spec:
  gatewayClassName: ${GWCLASS:-traefik}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - { kind: Secret, name: podinfo-tls }
      allowedRoutes:
        namespaces: { from: All }
EOF

kubectl apply -f 40-gateway-tls.yaml
```

Port 443 maps to Traefik's `websecure` entryPoint. You need a second reachable URL for it — either
the LoadBalancer address, or a second port-forward:

```bash
# Option B: in another terminal
kubectl -n kube-system port-forward svc/traefik 8443:443
```

```bash
export GW_TLS_PORT=8443
curl -sk --resolve gw.podinfo.lab:${GW_TLS_PORT}:127.0.0.1 \
  https://gw.podinfo.lab:${GW_TLS_PORT}/shop/ | jq -r .message
```

`--resolve` is what makes SNI and the `Host` header agree while still connecting to your local
forwarded port. Without it you would get a certificate name mismatch.

**HTTP → HTTPS redirect**, attached to the HTTP listener only via `sectionName`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tls-redirect
  namespace: demo
spec:
  parentRefs:
    - { name: web, namespace: infra, sectionName: http }
  hostnames:
    - gw.podinfo.lab
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
EOF
```

`sectionName` is what prevents a redirect loop on the HTTPS side.

> **Careful:** this route has no path match, so it competes with the Lab 5 routes on port 80.
> Observe the precedence, then decide which you want.

---

# Appendix B — Troubleshooting drills

Use as filler if a group finishes early, or as a closing exercise. Work in pairs: one person breaks
something while the other looks away, then the other diagnoses **using only `kubectl describe`**.

| # | Break | Expected condition |
|---|---|---|
| 1 | `parentRefs.name` → a nonexistent Gateway | No status parent — the Route is orphaned |
| 2 | `backendRefs.name` → a missing Service | `ResolvedRefs: False` / `BackendNotFound` |
| 3 | `backendRefs.port` → a port the Service does not expose | `ResolvedRefs: False` |
| 4 | Remove a namespace's `gateway-access` label | `Accepted: False` / `NotAllowedByListeners` |
| 5 | Delete the Lab 7 ReferenceGrant | `ResolvedRefs: False` / `RefNotPermitted` |
| 6 | `sectionName` → a nonexistent listener | `Accepted: False` / `NoMatchingParent` |
| 7 | `gatewayClassName` → a class no controller owns | Gateway never becomes `Accepted` |
| 8 | Listener port with no Traefik entryPoint | Listener not `Programmed` (**⚠ VERIFY** reason) |
| 9 | `certificateRefs` → a Secret in another namespace, no grant | Listener `ResolvedRefs: False` / `RefNotPermitted` |

**Reason strings are part of the spec** — consistent across conformant implementations, so a runbook
written today survives a change of vendor.

---

# Appendix C — Where to go next

- **Fleet / GitOps split.** Gateways in the platform repo, Routes in app repos. Two `GitRepo`
  objects, different targets. Your `~/lab` git history is already the shape of this.
- **Traefik middlewares via `ExtensionRef`** — rate limiting, auth, circuit breaking. Typed and
  status-visible, but not portable.
- **`BackendTLSPolicy`** — Standard-channel re-encryption Gateway → backend.
- **GAMMA** — attach an HTTPRoute to a `Service` as `parentRef` for east-west routing.
- **Hostname ownership admission policy** — the Lab 7.4 gap. Kyverno or `ValidatingAdmissionPolicy`.
- **Experimental channel** — required for `TCPRoute`/`UDPRoute` on Traefik. Install upstream
  `experimental-install.yaml` matching your Traefik's Gateway API version, then set
  `providers.kubernetesGateway.experimentalChannel: true`.

---

# Appendix D — If you must use another implementation

Labs 4–7 are spec-standard and portable. What changes:

| Concern | Traefik (RKE2) | Envoy Gateway / NGF |
|---|---|---|
| Install | `ingress-controller: traefik` + HelmChartConfig | Helm chart, bring-your-own |
| Support | SUSE-packaged and supported | Community / vendor, not SUSE |
| GatewayClass | Pre-created by the provider | You create it |
| Listener ports | Must match an existing entryPoint | Arbitrary — infra provisioned per Gateway |
| Data plane | One shared Traefik | One deployment per Gateway |
| Exposure | Existing `traefik` Service | New Service per Gateway |
| Policy CRDs | `traefik.io/Middleware` via `ExtensionRef` | `SecurityPolicy`, `BackendTrafficPolicy` |

**Recommendation:** teach Traefik. If a customer has a concrete feature gap, be explicit about the
support consequences before recommending an alternative.

---

# Teardown

```bash
./scripts/90-teardown.sh          # namespaces and routes
./scripts/90-teardown.sh --all    # also disables the Gateway provider — READ THE PROMPT
```

By hand:

```bash
kubectl delete namespace demo team-a team-b infra --ignore-not-found
```

Your `~/lab` git repository is on your own machine and is untouched. It is the record of the
session — keep it. Destroying the cluster is a VM operation, not a `kubectl` call; ask your
instructor.

> **Do not** disable Traefik to "clean up" on an RKE2 release older than the April 2026 patches —
> it takes the Gateway API CRDs, and every Gateway and Route, with it. See Lab 3.2.
