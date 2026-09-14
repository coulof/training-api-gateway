---
marp: true
theme: default
paginate: true
size: 16:9
title: "User Namespaces & In-Place Pod Vertical Scaling on RKE2"
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
footer: "User Namespaces & In-Place Vertical Scaling — SUSE Consulting"
---

<!-- _class: lead -->
<!-- _paginate: false -->

# User Namespaces & In-Place Vertical Scaling

## Hardening Node Security & Zero-Downtime Resource Resizing on RKE2 1.36

**Hands-on Workshop**
Florian Coulombel — SUSE Consulting

---

# Workshop Agenda & Schedule

**Modern Pod primitives delivered in Kubernetes 1.36 ("Haru") on RKE2.**

| Time | Module & Focus | Type | Key Outcomes |
|:---:|---|:---:|---|
| **00:00** | **1. User Namespaces (`hostUsers: false`)** | Theory & Lab 1 | Root UID remapping & hostPath breakout containment |
| **00:45** | **2. Container In-Place Vertical Scaling** | Theory & Lab 2 | Live cgroup v2 patch without Pod restarts (`restartCount: 0`) |
| **01:30** | ☕ *Coffee Break (15 min)* | — | — |
| **01:45** | **3. Pod-Level Aggregate Scaling** | Theory & Lab 3 | Shared resource pools across multi-container / sidecar pods |
| **02:15** | **4. Enterprise Combos (Gateway + CEL)** | Lab 4 & 5 | Zero-downtime traffic proof & Fleet GitOps enforcement |
| **02:45** | **5. Discovery, Architecture & Wrap-up** | Synthesis | Kernel baselines, silent no-op gotchas & SoW checklist |

---

<!-- _class: lab -->

# Your Lab Environment & Pre-Flight Check

- Tested on **RKE2 1.36.x** (default in Rancher 2.15) with Linux kernel **≥ 6.3** and **cgroup v2**
- Verify specialized host & runtime prerequisites before starting:

```bash
export KUBECONFIG=./gwapi-lab.kubeconfig

# Run the dedicated user namespaces & resize pre-flight check:
./userns-vertical-scaling/00-check-prereqs-userns.sh
```

**What the checker validates:**
- `kubectl` client ≥ 1.32 (required for `--subresource resize`)
- Server version ≥ 1.36.0 (GA User Namespaces & Beta Pod-Level Resize)
- Node kernel ≥ 6.3 across all nodes (idmap mount support)
- CRI runtime engine (containerd 2.0+ / CRI-O)

---

<!-- _class: divider -->

# Part 1: User Namespaces
## Defusing the "Root-in-Container" Threat Model

---

# 🧊 Warm-up: How Do We Secure Pods Today?

**The 4 Core Linux Container Security Primitives:**
- **Namespaces:** Isolates **visibility** (private mount `/`, PIDs, network stack).
- **Cgroups:** Enforces **resource limits** (prevents CPU/memory noisy-neighbor DoS).
- **Capabilities:** Restricts **kernel privileges** (drops module loading, raw I/O).
- **Seccomp:** Filters **system calls** (blocks dangerous kernel syscalls like `ptrace`).

**Pop Quiz:** *"If a Pod runs as `runAsUser: 0`, what user is that on the host node?"*
➔ **Answer: Root (UID 0)!** Zero user ID isolation exists by default.

<!--
Presenter notes:
Ask the room to raise hands on the pop quiz before revealing the answer.
Most participants assume namespaces isolate user identity and think container root is virtual.
Deliver the punchline: To the host kernel, UID 0 is the exact same root running systemd and the node!
-->

---

# The 8 Linux Kernel Namespaces

<style scoped> table { font-size: 0.62em; width: 100%; } </style>

| Namespace | Linux Kernel | What It Isolates | In K8s by default? |
|---|---|---|:---:|
| **Mount (`mnt`)** | 2.4.19 (2002) | Filesystem mount points & root directory (`/`) | ✅ **Yes** (since v1.0, 2015) |
| **UTS (Hostname)** | 2.6.19 (2006) | Hostname & NIS domain name | ✅ **Yes** (since v1.0, 2015) |
| **IPC (`ipc`)** | 2.6.19 (2006) | System V IPC & POSIX message queues | ✅ **Yes** (since v1.0, 2015) |
| **Process ID (`pid`)** | 2.6.24 (2008) | Process IDs (container sees itself as `PID 1`) | ✅ **Yes** (since v1.0, 2015) |
| **Network (`net`)** | 2.6.29 (2009) | Network devices, IPs, routes, packet filtering | ✅ **Yes** (since v1.0, 2015) |
| **User (`user`)** | 3.8 (2013) | **User IDs (UID), Group IDs (GID) & root powers** | ❌ **NO! (GA in 1.36, 2026)** |
| **Cgroup (`cgroup`)** | 4.6 (2016) | `/proc/self/cgroup` and hierarchy view | ✅ **Yes** (v1.10+, 2018) |
| **Time (`time`)** | 5.6 (2020) | Monotonic and boot system clocks | ✅ **Yes** (v1.22+, 2021) |

<span class="small">`user` existed in Linux since 2013, but was unisolated in Kubernetes for 11 years until K8s 1.36.</span>

---

# Visibility Isolation vs. Kernel Identity

**"If a Pod runs as `runAsUser: 0`, isn't it still trapped in its namespaces?"**

- **YES! Visibility Isolation is intact:**
  - `mnt` (Mount): Private container rootfs; cannot see the host's `/`.
  - `pid` (Process): Process tree starts at `PID 1`; cannot see host processes.
  - `net` (Network): Private virtual ethernet interface, IP, and routing table.
- **The Security Flaw:**
  - **Namespaces isolate visibility (what a process sees), NOT identity (who the kernel authorizes).**
  - Without User Namespaces, the process credential is **`UID 0 in init_user_ns`**.

---

# The Container Breakout Threat Model

> *"Without using a user namespace a container running as root, in the case of a container breakout, has root privileges on the node... None of this is true when we use user namespaces."*
> — **Kubernetes Official Documentation** (`concepts/workloads/pods/user-namespaces`)

- **1. Host Mounts & Sockets (`hostPath`):**
  - Mounting `/tmp` or containerd sockets into the pod.
  - Host DAC checks `euid == 0` against root-owned files ➔ **Allowed immediately**.
- **2. Runtime & Kernel Breakout CVEs:**
  - Container engine escapes (CVE-2019-5736, CVE-2024-21626).
  - An escaping `UID 1000` process lands as an unprivileged user on the node.
  - An escaping `UID 0` process lands with **full host root authority** and owns the node!

<span class="warn">A container escape by UID 0 results in instant node compromise.</span>

---

# Why 13 Years in the Making? (2013 ➔ 2026)

- **2013: Linux Kernel 3.8 Merges `user_namespaces`**
  - Why couldn't Kubernetes v1.0 (2015) simply enable it?
- **The Blocker: The Recursive `chown` Storage Trap**
  - If container UID 0 maps to host UID 100000, persistent storage files must be owned by UID 100000.
  - Kubelet would need to recursively `chown` multi-terabyte PVCs on every pod boot ➔ ruined disk IOPS and prevented volume sharing.
- **The Kernel Breakthrough: `idmapped mounts` (Christian Brauner)**
  - **Linux 5.12 (2021):** VFS in-memory UID translation without on-disk chown ([`Documentation/filesystems/idmappings.rst`](https://docs.kernel.org/filesystems/idmappings.html)).
  - **Linux 6.3 (2023):** `tmpfs` idmap support merged ➔ unlocks K8s Secrets & ServiceAccount tokens!
- **The Ecosystem Alignment (2023–2026):**
  - CRI proto updates, containerd 2.0+, runc 1.2+, and [KEP-127](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/127-user-namespaces) graduation (Alpha 1.25 ➔ GA 1.36).

---

# Enabling User Namespaces: spec.hostUsers

Activate user namespaces with one declarative field:

```yaml
spec:
  hostUsers: false
```

- **Top-Level Symmetry:**
  - `hostNetwork: false` (Private NetNS) │ `hostPID: false` (Private PIDNS)
  - **`hostUsers: false` [NEW in 1.36] (Private UserNS)**
- **How It Operates Under the Hood:**
  - Kubelet assigns an unprivileged subordinate range (e.g. 65,536 IDs per pod via `subidsPerPod`).
  - **Inside container:** Process is UID 0 (package managers, root daemons work seamlessly).
  - **On host node:** Process runs as unprivileged `UID 100000+` with **zero host capabilities**.

---

# Architecture: UID Remapping & idmap Mounts

<style scoped> pre { font-size: 0.65em; line-height: 1.20; } </style>

```text
    ┌─────────────────────────────────────────────────────────────┐
    │ Inside Container (Pod: userns-demo)                         │
    │ Process: sleep 3600               UID: 0 (root)             │
    │ SecurityContext: runAsUser: 0     GID: 0 (root)             │
    └──────────────────────────────┬──────────────────────────────┘
                                   │ hostUsers: false
                                   ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ Linux Kernel 6.3+ (idmap mount & user namespace translation)│
    │ [Container UID 0] ─────────────► [Host UID 100000]          │
    │ [Container GID 0] ─────────────► [Host GID 100000]          │
    └──────────────────────────────┬──────────────────────────────┘
                                   ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ Host Node (RKE2 Node Kernel & Host OS)                      │
    │ Process on Host:                  UID: 100000 (unprivileged)│
    │ Host Filesystem writes:           Owner: 100000 (No Root!)  │
    └─────────────────────────────────────────────────────────────┘
```

---

<!-- _class: lab -->

# Lab 1a: User Namespaces Baseline

Deploy a pod running as root (`runAsUser: 0`) with `hostUsers: false`:

<style scoped> pre { font-size: 0.62em; line-height: 1.20; } </style>

```bash
kubectl apply -f userns-vertical-scaling/manifests/01-userns-pod.yaml

# 1. Inspect UID inside the container:
kubectl -n userns-lab exec userns-demo -- id
# Output: uid=0(root) gid=0(root) groups=0(root)

# 2. Inspect the process from the host node:
ps -eo pid,uid,cmd | grep 'sleep 3600'
# Result: The UID is a high unprivileged value (e.g. 100000), NOT 0!
```

**The Takeaway:** The application enjoys full root capabilities inside its container namespace, but has zero privileged access on the underlying node.

---

<!-- _class: lab -->

# Lab 1b: HostPath Breakout Containment

Test what happens when a container writes to a shared `hostPath` volume:

<style scoped> pre { font-size: 0.62em; line-height: 1.20; } </style>

```bash
kubectl apply -f userns-vertical-scaling/manifests/01b-userns-hostpath.yaml

# Check the file written on the node's /tmp:
ls -l /tmp/from-container.txt
```

```text
-rw-r--r-- 1 100000 100000 25 Aug 28 14:00 /tmp/from-container.txt
```

- **Without User Namespaces:** The file is owned by `root:root` (UID 0), allowing privilege escalation or tampering with host files.
- **With `hostUsers: false`:** The file is owned by `100000:100000`. The host kernel prevents overwriting root files (`/etc/shadow`, `/usr/bin`).

---

# Critical Gotchas & Enterprise Positioning

- **⚠️ The Silent No-Op Gotcha:**
  - If a node runs Linux kernel **< 6.3**, Kubernetes 1.36 **silently schedules the pod without UID remapping**.
  - No error, no warning event, no admission rejection!
  - Always validate node kernel baselines during customer discovery.
- **Air-Gapped & Sovereign Clusters:**
  - For defense, banking, and public sector clouds running **SLE Micro / RKE2**.
  - **Synergy with NeuVector:** User namespaces provide cheap, kernel-enforced containment at the bottom; NeuVector provides Layer-7 DPI, behavioral learning, and admission controls at the top.

---

<!-- _class: divider -->

# Part 2: Container In-Place Vertical Scaling
## Live Resizing Without Pod Recreations

---

# The Problem: Pod Recreations Break Production

- **Traditional Kubernetes Scaling:**
  - Modifying `.spec.containers[*].resources` was **immutable**.
  - Updating resources required terminating the pod and creating a new one.
- **Why Pod Restarts Hurt:**
  1. **JVM / Node.js Warmup:** Cold cache penalties and latency spikes.
  2. **In-Flight Connection Drop:** Dropped TCP sessions and client errors.
  3. **Stateful & AI/GPU Workloads:** Long checkpoint loading times (KubeVirt, vLLM, Training Operator).
  4. **Autoscaling Inefficiency:** VPA evictions causing cluster-wide churn.

---

# The Solution: In-Place Vertical Scaling (GA)

- **Graduated to GA in Kubernetes 1.35:**
  - Mutation of `.spec.containers[*].resources` on running pods.
  - Kubelet calls CRI `UpdateContainerResources` to adjust **cgroup v2** limits live.
- **The `resizePolicy` Specification:**
  - Control whether CPU or Memory adjustments require a container restart:
  ```yaml
  spec:
    containers:
    - name: app
      resizePolicy:
      - resourceName: cpu
        restartPolicy: NotRequired
      - resourceName: memory
        restartPolicy: NotRequired
  ```

---

# Architecture: Eviction vs In-Place Cgroup Patch

<style scoped> pre { font-size: 0.63em; line-height: 1.18; } </style>

```text
  [ Traditional Pod Recreation ]
  PATCH spec.resources ──► Pod TERMINATING ──► Endpoint Removed ──► New Pod PENDING
                           (Dropped Conns)   (DNS / IP Churn)     (Cold Start Warmup)

  ───────────────────────────────────────────────────────────────────────────────────

  [ In-Place Vertical Scaling (GA) ]
  PATCH --subresource resize
           │
           ▼
    API Server (Validates & Updates Pod Status) ──► Kubelet (Reconciles cgroups)
                                                            │
                                                            ▼ CRI: UpdateContainerResources
    Active Container (cgroup limits updated live ──► 0 restarts, 0 IP change!)
```

---

<!-- _class: lab -->

# Lab 2: Container In-Place Resize in Action

Deploy a pod burning CPU pinned at `200m` CPU limit:

<style scoped> pre { font-size: 0.62em; line-height: 1.20; } </style>

```bash
kubectl apply -f userns-vertical-scaling/manifests/02-resize-container.yaml

# Confirm initial CPU throttling (pinned near 200m):
kubectl -n userns-lab top pod resize-demo --containers

# Live patch the CPU limit from 200m to 1000m (1 core):
kubectl -n userns-lab patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"burn","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"1"}}}]}}'

# Check resize conditions and verify 0 restarts:
kubectl -n userns-lab get pod resize-demo -o jsonpath='{.status.conditions}' | jq .
kubectl -n userns-lab get pod resize-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'
# Output: 0
```

---

# Understanding Resize Status Conditions

During an in-place resize, Kubernetes updates `status.conditions`:

1. **`PodResizePending`:**
   - The resize request was accepted by the API server, waiting for node kubelet acknowledgment.
2. **`PodResizeInProgress`:**
   - Kubelet has acknowledged the request and is updating runtime cgroup limits.
3. **Condition Clears (Success):**
   - Runtime updated cgroups; `status.containerStatuses[*].resourcesAllocated` matches desired `spec.resources`.

- **Handling Memory Decreases:**
  - If a memory reduction would trigger an immediate OOM (container currently using more memory than new limit), kubelet defers or rejects the shrink for safety.

---

<!-- _class: divider -->

# Part 3: Pod-Level Aggregate Scaling
## Shared Resource Pools in Kubernetes 1.36

---

# The "Sidecar Tax" & Resource Fragmentation

- **The Multi-Container Dilemma:**
  - Modern Kubernetes pods run multiple containers: Application + Envoy/Service Mesh sidecar + Log forwarder (Fluentbit) + Vault agent.
- **The Problem with Per-Container Limits:**
  - Assigning rigid limits to each container leads to wasted headroom.
  - If the sidecar bursts during high log volume, it gets OOMKilled even if the application container is completely idle.
- **The Solution: Pod-Level Resources (Beta in 1.36):**
  - Define an aggregate `spec.resources` budget for the **entire pod**.
  - All containers share the pool dynamically.

---

# Specifying Pod-Level Resource Budgets

In Kubernetes 1.36, define `resources` directly under `spec`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: podlevel-resize-demo
  namespace: userns-lab
spec:
  resources:
    limits:
      cpu: "500m"
      memory: "256Mi"
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "yes > /dev/null & sleep 3600"]
  - name: sidecar
    image: busybox:1.36
    command: ["sleep", "3600"]
```

Neither container has individual limits — both draw from the shared 500m pool!

---

<!-- _class: lab -->

# Lab 3: Live Pod-Level Aggregate Resize

Scale the shared pool from `500m` to `1500m` without modifying container specs:

<style scoped> pre { font-size: 0.62em; line-height: 1.20; } </style>

```bash
kubectl apply -f userns-vertical-scaling/manifests/03-resize-podlevel.yaml

# Check current allocated pod resources:
kubectl -n userns-lab get pod podlevel-resize-demo -o jsonpath='{.status.resources}' | jq .

# Patch the aggregate pod budget:
kubectl -n userns-lab patch pod podlevel-resize-demo --subresource resize --patch \
  '{"spec":{"resources":{"limits":{"cpu":"1500m"}}}}'

# Observe status conditions and allocated budget update:
kubectl -n userns-lab get pod podlevel-resize-demo -o jsonpath='{.status.conditions}' | jq .
```

**Key Benefit:** You can dynamically scale sidecar-heavy pods without maintaining bespoke sizing logic for every individual sidecar container.

---

# VPA Integration & CPU Startup-Boost

- **Vertical Pod Autoscaler (VPA) `InPlaceOrRecreate` Mode:**
  - VPA can now right-size pods live without evicting them.
  - Ideal for long-running batch jobs, ML training (Katib), and KubeVirt VMs.
- **CPU Startup-Boost Pattern:**
  - Cold starts (JVM class loading, model loading) require high CPU for 15 seconds.
  - Pod starts with high initial CPU limits.
  - Controller automatically patches pod limits down in-place once readiness probe succeeds.

---

<!-- _class: divider -->

# Part 4: Enterprise Combos
## Zero-Downtime Proof & Fleet GitOps Enforcement

---

<!-- _class: lab -->

# Lab 4 (Combo): Proving Zero Downtime

Deploy `podinfo` behind a Gateway API `HTTPRoute` and run sustained traffic:

<style scoped> pre { font-size: 0.62em; line-height: 1.20; } </style>

```bash
kubectl apply -f userns-vertical-scaling/manifests/04-podinfo-continuity.yaml

# 1. In terminal 1: Launch the traffic continuity benchmark
./userns-vertical-scaling/measure-resize-continuity.sh -u http://127.0.0.1:8080/version -d 20

# 2. In terminal 2: Live resize the pod
POD=$(kubectl -n userns-lab get pod -l app=podinfo-resize -o jsonpath='{.items[0].metadata.name}')
kubectl -n userns-lab patch pod "$POD" --subresource resize --patch \
  '{"spec":{"containers":[{"name":"podinfo","resources":{"requests":{"cpu":"250m"},"limits":{"cpu":"500m"}}}]}}'
```

- **Result:** `0% dropped requests`, `0 latency spikes`.
- **Contrast:** Repeat with `kubectl rollout restart deployment/podinfo-resize` — observe immediate dropped packets during endpoint churn!

---

<!-- _class: lab -->

# Lab 5 (Combo): Fleet GitOps CEL Admission

Enforce `hostUsers: false` cluster-wide using native K8s 1.36 CEL policies:

<style scoped> pre { font-size: 0.62em; line-height: 1.18; } </style>

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: force-userns
spec:
  matchConstraints:
    resourceRules:
    - { apiGroups: [""], apiVersions: ["v1"], resources: ["pods"], operations: ["CREATE"] }
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: 'Object{spec: Object.spec{hostUsers: false}}'
```

- **Why this matters for Rancher / Fleet:**
  - Zero webhook pods to deploy, patch, or maintain.
  - Native Kubernetes CEL evaluation at the API server layer.

---

<!-- _class: divider -->

# Part 5: Production Discovery & Summary
## Delivering Value on RKE2 & Rancher

---

# Customer Discovery & SoW Checklist

Before promising User Namespaces or In-Place Resize in an engagement:

| Requirement | Target Feature | Validation Command |
|---|---|---|
| **Linux Kernel ≥ 6.3** | User Namespaces | `uname -r` or `status.nodeInfo.kernelVersion` |
| **idmap filesystem** | User Namespaces | `df -T /var/lib/kubelet` (`ext4/xfs/btrfs`) |
| **cgroup v2** | In-Place Resize | `cat /sys/fs/cgroup/cgroup.controllers` |
| **containerd ≥ 2.0** | Pod-Level Resize | `crictl info \| grep containerd` |
| **kubectl ≥ 1.32** | CLI resize patch | `kubectl version --client` |

<span class="warn">Discovery Rule: Kernel and cgroup v2 cannot be retrofitted without OS/node upgrades. Always verify before designing the architecture.</span>

---

# Summary: Container Root vs. Host Security Matrix

| Configuration | Mount & Process Isolation | Host Kernel Identity | Breakout Blast Radius |
|---|---|---|---|
| **Default K8s (`runAsUser: 0`)** | Private `mnt`, `pid`, `net` | `UID 0 in init_user_ns` | 🚨 **Host Root Takeover** (Host root authority) |
| **Legacy Fix (`runAsUser: 1000`)** | Private `mnt`, `pid`, `net` | `UID 1000 in init_user_ns` | 🛡️ **Unprivileged**, *breaks apps needing root inside!* |
| **User Namespaces (`hostUsers: false`)** | Private `mnt`, `pid`, `net`, `user` | **`UID 100000+`** | 🛡️ **Zero Host Privilege** (Full root inside container) |

<span class="small">Delivered natively in Kubernetes 1.36 on RKE2 with Linux kernel ≥ 6.3.</span>

---

# Summary & Key Takeaways

1. **User Namespaces (`hostUsers: false`):**
   - Stable/GA in 1.36. Container root is unprivileged on host.
   - Essential defense-in-depth control for air-gapped/sovereign RKE2 clusters.
   - Beware the silent no-op on kernels < 6.3.
2. **Container In-Place Vertical Scaling:**
   - Stable/GA in 1.35+. Updates cgroup v2 limits live with `restartCount: 0`.
   - Eliminates cold starts, connection drops, and endpoint churn.
3. **Pod-Level Aggregate Scaling:**
   - Beta in 1.36. Solves the multi-container / sidecar overhead problem.
4. **GitOps & Fleet Synergy:**
   - Enforce security and scaling policies declaratively using CEL Mutating Admission.

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Thank you!

## Questions & Hands-on Discussion

**Florian Coulombel — SUSE Consulting**
*User Namespaces & In-Place Pod Vertical Scaling on RKE2 1.36*
