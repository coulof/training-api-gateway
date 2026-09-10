# User Namespaces & In-Place Pod Vertical Scaling on RKE2 1.36

> **Hands-on Workshop & Technical Guide**  
> *Target Stack:* Kubernetes 1.36 ("Haru") / RKE2 1.36.x / Rancher 2.15 / SLE Micro

---

## 🎯 Workshop Overview

This training explores two critical pod-level enhancements delivered in **Kubernetes 1.36**:

1. **User Namespaces (`hostUsers: false` — Stable/GA in 1.36):**  
   Eliminates the legacy container security risk where *root-in-container == root-on-host*. Container UID 0 is mapped to an unprivileged subordinate UID (`100000+`) on the Linux host kernel via `idmapped mounts`.
2. **In-Place Pod Vertical Scaling:**
   * **Container-Level Resize (GA in 1.35+):** Mutate `.spec.containers[*].resources` on running pods without restart or recreation (`restartCount: 0`).
   * **Pod-Level Aggregate Resize (Beta in 1.36):** Define a shared resource budget across multi-container / sidecar-heavy pods (`spec.resources`) and scale the entire pool dynamically.

### 🔬 Architecture Deep Dive: Capabilities, `securityContext` & User Namespaces

Kubernetes engineers use `securityContext` daily, but what does it actually map to in the Linux kernel?

| Kubernetes YAML Field | Underlying Linux Kernel Primitive | Behavior without userns (`hostUsers: true`) | Behavior with userns (`hostUsers: false`) |
|---|---|---|---|
| `runAsUser: 0` | Process credential (`setuid(0)`) | ⚠️ **Dangerous:** Real root on host kernel (`UID 0 in init_user_ns`). | 🛡️ **Safe:** Container sees UID 0; host kernel maps to unprivileged `UID 100000+`. |
| `runAsNonRoot: true` | Admission validation check | **Mandatory legacy workaround:** Used for 10 years to stop root escapes. Breaks vendor COTS. | **Defense-in-depth:** Still good practice, but root inside container no longer threatens host. |
| `capabilities.add: ["NET_ADMIN"]` | Capability bounding set (`cap_effective`) | 💥 **Host threat:** Can manipulate host network interfaces or routing tables. | 🔒 **Scoped:** Can configure interfaces **only inside the pod's private netns**. Zero host access. |
| `privileged: true` | Full host device & capability access | Grants full root and device access on the host node. | 🚫 **Forbidden:** K8s API server rejects `privileged: true` when `hostUsers: false` is set. |
| `allowPrivilegeEscalation: false` | `prctl(PR_SET_NO_NEW_PRIVS)` | Prevents `setuid` binary escalation. | Prevents `setuid` binary escalation inside container userns. |

* **Why is `hostUsers` a top-level `spec` field, not inside `securityContext`?**  
  Just like `spec.hostNetwork` and `spec.hostPID`, a Linux User Namespace is shared across **all containers in a Pod**. Therefore, it is declared at the Pod level (`spec.hostUsers: false`).
* **Discretionary Access Control (DAC) Trap:** Host node files (`/etc`, `/run/containerd.sock`, `/var/lib/kubelet`) are owned by `UID 0`. If a process breaks out (via `hostPath` or runc CVEs), the kernel's DAC engine allows `UID 0` without requiring special capabilities because it *is* root. User namespaces eliminate this by ensuring container root is never host root.

#### 📚 Upstream Specifications & Kernel Sources

* **Linux Kernel idmapped mounts:**
  * Created by Christian Brauner in Linux 5.12, expanded to OverlayFS in 5.19 and 6.3+.
  * [Linux Kernel Documentation: `Documentation/filesystems/idmappings.rst`](https://docs.kernel.org/filesystems/idmappings.html)
  * [LWN.net: Extending idmapped mounts to overlayfs](https://lwn.net/Articles/896255/)
* **Kubernetes Upstream Tracking & KEPs:**
  * **KEP-127:** [*Support User Namespaces in Pods*](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/127-user-namespaces) (`kubernetes/enhancements#127`)
  * **k/k Tracking Issue:** [`kubernetes/kubernetes#102394`](https://github.com/kubernetes/kubernetes/issues/102394)
  * **Core PRs:** Alpha in 1.25 ([#111847](https://github.com/kubernetes/kubernetes/pull/111847)), Beta in 1.30 ([#120406](https://github.com/kubernetes/kubernetes/pull/120406)), GA in 1.36 ([#127394](https://github.com/kubernetes/kubernetes/pull/127394)).

---

## ⏱️ Schedule & Agenda (3h)

| Time | Module & Topic | Hands-on Labs & Focus |
|:---:|---|---|
| **00:00 – 00:45** | **Part 1 — User Namespaces** | • **Lab 1a:** `hostUsers: false` baseline pod (`ps -eo pid,uid,cmd`)<br>• **Lab 1b:** HostPath breakout containment & UID remapping |
| **00:45 – 01:30** | **Part 2 — Container In-Place Scaling (GA)** | • **Lab 2:** CPU load test under live `kubectl patch --subresource resize`<br>• Inspecting `status.conditions` & `restartCount: 0` |
| **01:30 – 01:45** | ☕ **Coffee & Networking Break** | — |
| **01:45 – 02:15** | **Part 3 — Pod-Level Aggregate Scaling (Beta)** | • **Lab 3:** Shared `spec.resources` budget across multi-container pods |
| **02:15 – 02:45** | **Part 4 — Enterprise Combos (Gateway + CEL)** | • **Lab 4:** Zero-downtime benchmark (`measure-resize-continuity.sh`)<br>• **Lab 5:** Fleet GitOps CEL `MutatingAdmissionPolicy` |
| **02:45 – 03:00** | **Part 5 — Production Discovery & Wrap-up** | • Kernel baseline discovery checklist & SoW architecture rules |

---

## 📂 Directory Structure

```text
userns-vertical-scaling/
├── 00-check-prereqs-userns.sh           # Specialized pre-flight validation script
├── measure-resize-continuity.sh         # HTTP traffic continuity benchmark tool
├── 01-slides-userns-vertical-scaling.md # Marp slide deck source
├── deck.html                            # Interactive presentation HTML (Speaker notes on 'P')
├── deck.pdf                             # Distributable slide deck PDF
├── deck.pptx                            # PowerPoint presentation
├── README.md                            # This workbook
└── manifests/
    ├── 01-userns-pod.yaml               # Lab 1a: hostUsers: false baseline pod
    ├── 01b-userns-hostpath.yaml         # Lab 1b: hostPath breakout UID remapping proof
    ├── 02-resize-container.yaml         # Lab 2: Container-level in-place resize (GA)
    ├── 03-resize-podlevel.yaml          # Lab 3: Pod-level aggregate resize (Beta 1.36)
    ├── 04-podinfo-continuity.yaml       # Lab 4: Podinfo + Gateway HTTPRoute continuity test
    └── 05-fleet-cel-mutating-policy.yaml# Lab 5: Fleet CEL MutatingAdmissionPolicy
```

---

## 🚀 Step-by-Step Hands-on Labs

### Pre-Flight: Specialized Prerequisites Checker

Run the dedicated prerequisite checker against your cluster:

```bash
export KUBECONFIG=~/gwapi-lab.kubeconfig
./userns-vertical-scaling/00-check-prereqs-userns.sh
```

**Validated parameters:**
* `kubectl` client version ≥ `1.32` (required for `--subresource resize`).
* Server version ≥ `1.36.0`.
* Linux kernel ≥ `6.3` across all nodes (required for `idmap` mounts).
* Container runtime `containerd` ≥ `2.0` or CRI-O.

---

### Lab 1a — User Namespaces Baseline (`hostUsers: false`)

Deploy a pod running as UID 0 (root) inside the container, with user namespaces enabled:

```bash
kubectl apply -f userns-vertical-scaling/manifests/01-userns-pod.yaml

# 1. Check identity inside the container:
kubectl -n userns-lab exec userns-demo -- id
# Output: uid=0(root) gid=0(root) groups=0(root)

# 2. Check identity from the host node (SSH or node command):
ps -eo pid,uid,cmd | grep 'sleep 3600'
# Output: The UID on the host is 100000+ (an unprivileged subordinate UID)!
```

---

### Lab 1b — HostPath Breakout Containment

Verify that even if a container writes directly to a mounted node filesystem (`/tmp`), the resulting file is owned by the unprivileged subordinate UID:

```bash
kubectl apply -f userns-vertical-scaling/manifests/01b-userns-hostpath.yaml

# Check ownership of the created file on the node:
ls -l /tmp/from-container.txt
# Output: -rw-r--r-- 1 100000 100000 25 Aug 28 14:00 /tmp/from-container.txt
```

> **⚠️ Critical Discovery Rule:** If a node runs a Linux kernel **< 6.3**, Kubernetes 1.36 silently schedules pods **without UID remapping** (no error, no admission rejection). Always verify `uname -r >= 6.3`.

---

### Lab 2 — Container-Level In-Place Vertical Scaling (GA)

Deploy a CPU-bound container with initial limits set to `200m`:

```bash
kubectl apply -f userns-vertical-scaling/manifests/02-resize-container.yaml

# Inspect initial CPU throttling (pinned around 200m):
kubectl -n userns-lab top pod resize-demo --containers

# Live patch the CPU limit to 1000m (1 core) without restarting the pod:
kubectl -n userns-lab patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"burn","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"1"}}}]}}'

# Verify that no restart occurred:
kubectl -n userns-lab get pod resize-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'
# Output: 0
```

---

### Lab 3 — Pod-Level Aggregate Scaling (Beta in 1.36)

Scale an aggregate `spec.resources` pool shared across multiple containers (`app` + `sidecar`):

```bash
kubectl apply -f userns-vertical-scaling/manifests/03-resize-podlevel.yaml

# Inspect current aggregate budget:
kubectl -n userns-lab get pod podlevel-resize-demo -o jsonpath='{.status.resources}' | jq .

# Patch the aggregate limit from 500m to 1500m:
kubectl -n userns-lab patch pod podlevel-resize-demo --subresource resize --patch \
  '{"spec":{"resources":{"limits":{"cpu":"1500m"}}}}'

# Confirm live allocation:
kubectl -n userns-lab get pod podlevel-resize-demo -o jsonpath='{.status.conditions}' | jq .
```

---

### Lab 4 (Combo) — Zero-Downtime Traffic Continuity Benchmark

Demonstrate that in-place resizing eliminates connection drops compared to traditional rollout restarts:

```bash
kubectl apply -f userns-vertical-scaling/manifests/04-podinfo-continuity.yaml

# 1. In Terminal 1: Start sustained HTTP traffic probes
./userns-vertical-scaling/measure-resize-continuity.sh -u http://127.0.0.1:8080/version -d 20

# 2. In Terminal 2: Live resize the active pod
POD=$(kubectl -n userns-lab get pod -l app=podinfo-resize -o jsonpath='{.items[0].metadata.name}')
kubectl -n userns-lab patch pod "$POD" --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"250m"},"limits":{"cpu":"500m"}}}]}}'
```

* **In-Place Resize:** `100% 200 OK`, `0 dropped requests`.
* **Rollout Restart Contrast:** Run `kubectl -n userns-lab rollout restart deployment/podinfo-resize` while probing—observe dropped connections and latency spikes during pod termination.

---

### Lab 5 (Combo) — Fleet GitOps CEL Policy Enforcement

Enforce `hostUsers: false` cluster-wide using native Kubernetes 1.36 Common Expression Language (CEL):

```bash
kubectl apply -f userns-vertical-scaling/manifests/05-fleet-cel-mutating-policy.yaml

# Label any namespace to enforce user namespaces:
kubectl label namespace userns-lab userns-enforced=true --overwrite
```

Any pod created in `userns-lab` will automatically have `hostUsers: false` injected without deploying custom webhook controllers.

---

## 📋 Production Discovery & Architecture Checklist

| Item | Requirement | Why It Matters |
|---|---|---|
| **Node Kernel** | Linux ≥ 6.3 | Required for `idmapped mounts` backing User Namespaces. |
| **Cgroup Hierarchy** | cgroup v2 | Required for dynamic cgroup limit adjustments. |
| **Container Runtime** | containerd ≥ 2.0 / CRI-O | Required for `UpdateContainerResources` CRI call. |
| **CLI Client** | `kubectl` ≥ 1.32 | Required for `--subresource resize` patch support. |
| **Security Synergy** | NeuVector + User Namespaces | Kernel-level UID isolation paired with Layer-7 DPI & Zero Trust. |
