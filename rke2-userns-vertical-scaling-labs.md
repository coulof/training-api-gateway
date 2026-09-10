# Labs: User Namespaces & In-Place Vertical Scaling on RKE2 1.36

Companion to the earlier memo. All labs assume a single-node (or small) RKE2 1.36.x cluster. Run Lab 0 first regardless of where the node lives.

---

## Lab 0 — Bootstrap an RKE2 1.36 node

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.36.4+rke2r1 INSTALL_RKE2_TYPE=server sh -
systemctl enable --now rke2-server

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes -o wide

# prerequisite checks — do these before anything else
uname -r                                # need >= 6.3 for user namespaces
cat /sys/fs/cgroup/cgroup.controllers   # non-empty output = cgroup v2 unified, good
crictl info | grep -i '"version"'       # confirm containerd build, want 2.0+ for pod-level resize CRI call
```

If you're spinning this up locally rather than on a spare box, your vfkit SLE Micro script is a fine base — just confirm the image kernel clears 6.3 before you bother installing RKE2 on it; if it doesn't, this is the wrong image to test user namespaces on.

Both feature gates (`InPlacePodVerticalScaling`, `InPlacePodLevelResourcesVerticalScaling`) are on by default in 1.36 — nothing to flip unless you've explicitly disabled feature gates in `/etc/rancher/rke2/config.yaml` for other reasons.

---

## Lab 1 — User namespaces (`hostUsers: false`)

```yaml
# lab1-userns-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-demo
spec:
  hostUsers: false
  containers:
  - name: shell
    image: busybox
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 0
```

```bash
kubectl apply -f lab1-userns-pod.yaml
kubectl exec userns-demo -- id
# uid=0(root) — looks like root from inside, as expected

# now look from the host side
ps -eo pid,uid,cmd | grep 'sleep 3600'
# uid here will be a large, non-zero, per-pod value — NOT 0
```

Re-run without `hostUsers: false` (or just `hostUsers: true`) and repeat the host-side `ps` — you'll see uid 0 on the host this time. That delta is the whole feature in one comparison.

**Breakout-relevant variant** — write to a `hostPath` mount as "root" and check ownership on the node:

```yaml
# lab1b-hostpath-write.yaml — sandbox nodes only, don't run this against anything you care about
apiVersion: v1
kind: Pod
metadata:
  name: userns-hostpath-demo
spec:
  hostUsers: false
  containers:
  - name: shell
    image: busybox
    command: ["sh", "-c", "echo pwned > /host-tmp/from-container.txt; sleep 3600"]
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: host-tmp
      mountPath: /host-tmp
  volumes:
  - name: host-tmp
    hostPath:
      path: /tmp
```

```bash
kubectl apply -f lab1b-hostpath-write.yaml
ls -l /tmp/from-container.txt    # on the node — owning UID is the remapped one, not root
```

---

## Lab 2 — Container-level in-place resize (GA)

```yaml
# lab2-resize-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: resize-demo
spec:
  containers:
  - name: burn
    image: busybox
    command: ["sh", "-c", "yes > /dev/null & yes > /dev/null & sleep 3600"]
    resources:
      requests: {cpu: "100m", memory: "64Mi"}
      limits: {cpu: "200m", memory: "128Mi"}
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired
    - resourceName: memory
      restartPolicy: NotRequired
```

```bash
kubectl apply -f lab2-resize-pod.yaml
kubectl top pod resize-demo --containers    # confirm it's pinned near the 200m limit

kubectl patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"burn","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"1"}}}]}}'

kubectl get pod resize-demo -o jsonpath='{.status.conditions}'
# watch PodResizePending -> PodResizeInProgress -> condition clears

kubectl top pod resize-demo --containers    # should climb toward 1 core
kubectl get pod resize-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'
# unchanged — no restart happened
```

---

## Lab 3 — Pod-level aggregate resize (beta, 1.36-only)

```yaml
# lab3-podlevel-resize.yaml
apiVersion: v1
kind: Pod
metadata:
  name: podlevel-resize-demo
spec:
  resources:                        # aggregate pod-level budget, shared across containers
    limits: {cpu: "500m", memory: "256Mi"}
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "yes > /dev/null & sleep 3600"]
  - name: sidecar
    image: busybox
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f lab3-podlevel-resize.yaml
kubectl get pod podlevel-resize-demo -o jsonpath='{.status.resources}'

kubectl patch pod podlevel-resize-demo --subresource resize --patch \
  '{"spec":{"resources":{"limits":{"cpu":"1500m"}}}}'

kubectl get pod podlevel-resize-demo -o jsonpath='{.status.conditions}'
```

Note neither container has its own individual limit — both draw from the shared pool, and the pool just grew without touching either container spec. This is the case worth calling out for sidecar-heavy pods (mesh proxies, log shippers) where you don't want to hand-tune every sidecar's own resources.

---

## Optional combos — only where they earn their place

### Worth doing: Gateway API + podinfo — proving "no restart" actually means "no disruption"

You already have the Traefik Gateway API training package, and this is a genuine use for it: the real selling point of in-place resize isn't the CPU number, it's that the pod's IP and identity don't change, so nothing upstream (kube-proxy, Traefik's endpoint list, in-flight connections) needs to re-resolve anything. That's demonstrable, not just assertable.

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm install podinfo podinfo/podinfo \
  --set resources.requests.cpu=100m --set resources.limits.cpu=200m
```

Point an `HTTPRoute` at it (reuse a Gateway from your training material):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: <your-gateway>
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
```

Drive sustained traffic through the route, then resize the live pod (not the Deployment — patching the Deployment template triggers a normal rollout and defeats the point):

```bash
while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://<gateway-address>/version; sleep 0.2; done &

POD=$(kubectl get pod -l app.kubernetes.io/name=podinfo -o jsonpath='{.items[0].metadata.name}')
kubectl patch pod "$POD" --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"250m"},"limits":{"cpu":"500m"}}}]}}'
```

You should see zero non-200s and no latency spike in the curl loop. Contrast with `kubectl rollout restart deploy/podinfo` on a second run — that one visibly drops or stalls a request or two as the old pod terminates and Traefik updates its endpoint list. That contrast is the demo.

One correction on an assumption you might reach for: podinfo has no built-in CPU-burn endpoint (`/delay`, `/status`, `/panic` are all latency/error fault injection, not CPU load) — don't build the CPU-pressure part of a demo around it. It's the right app for this connection-continuity angle, not for generating the load itself; keep `busybox`/`yes` for that, as in Labs 2 and 3.

### Worth doing: Rancher/Fleet — pushing `hostUsers: false` fleet-wide

For the air-gapped/sovereign engagements specifically, the interesting Rancher angle isn't a UI button (there isn't a dedicated one for resize or userns yet) — it's Fleet distributing a cluster-wide enforcement policy as GitOps, which is exactly the pattern you'd already use for those engagements:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: force-userns
spec:
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations: ["CREATE"]
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: >
        Object{spec: Object.spec{hostUsers: false}}
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: force-userns-binding
spec:
  policyName: force-userns
  matchResources:
    namespaceSelector:
      matchLabels:
        userns-enforced: "true"
```

Treat the CEL as a starting sketch, not copy-paste-verified — validate the exact `Object{}` expression against the 1.36 API reference before it goes anywhere near a customer cluster. The point worth showing is the mechanism: one Fleet-managed manifest, rolled out via GitOps to every downstream cluster in a fleet, no per-cluster webhook to deploy or keep patched. For Rancher's built-in monitoring (Grafana/Prometheus), it's fine for watching the live CPU/memory graph move during Lab 2/3's resize — nothing special there, just confirms the numbers you already saw via `kubectl top`.

### Not worth forcing

Nothing about user namespaces meaningfully interacts with Gateway API — UID remapping is a node/kernel-level concern, routing is L7. Skip trying to make that connection; it won't teach anything the Lab 1 host-side `ps` comparison doesn't already show more directly.
