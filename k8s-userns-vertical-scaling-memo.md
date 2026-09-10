# Memo: User Namespaces & In-Place Pod Vertical Scaling

**Date:** 2026-08-28
**Scope:** Kubernetes 1.36 ("Haru", released 2026-04-22) — both features are now shipping in RKE2 1.36.x, which Rancher 2.15 lists as its default version.

---

## 1. User Namespaces (`hostUsers: false`)

**Status:** Stable/GA as of Kubernetes 1.36 (alpha since 1.25, six years in development).

**What it does:** Maps a container's UID/GID range to an unprivileged range on the host. A process that's root (UID 0) inside the container is a non-privileged, per-pod-unique UID on the node. Without this, root-in-container == root-on-host if there's a breakout (kernel bug, bad mount, misconfigured hostPath).

**Enable per-pod:**
```yaml
spec:
  hostUsers: false
```

**Requirements:**
- Linux kernel ≥ 6.3 on every node (check with `kubectl get nodes -o custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion`)
- idmap-mount-capable filesystem under kubelet pod dir (ext4/xfs/btrfs/tmpfs on recent kernels are fine)
- CRI support (containerd/CRI-O current versions)

**Gotchas:**
- Silent no-op on old kernels/AMIs — pod still schedules and runs, just without UID remapping. No error, no warning. Worth an admission check if you care.
- `Mutating Admission Policies` (also GA in 1.36) is the clean way to force `hostUsers: false` cluster/namespace-wide without a webhook.
- Still Linux-only.

**Relevance to our stack:** On SLE Micro / RKE2 nodes this is a straightforward win for any air-gapped or defense-sector cluster where "root escape = node compromise" is the exact threat model we're mitigating with NeuVector today — this is a complementary, cheaper-to-operate control, not a replacement. Worth checking node kernel baseline before promising it in a SoW; some hardened/older SLE Micro images may not clear 6.3.

---

## 2. In-Place Pod Vertical Scaling

Two distinct features, easy to conflate:

| Feature | Feature gate | Status | Since |
|---|---|---|---|
| Container-level resize | `InPlacePodVerticalScaling` | **Stable/GA** | alpha 1.27 → beta 1.33 → GA 1.35 |
| Pod-level (aggregate) resize | `InPlacePodLevelResourcesVerticalScaling` | **Beta**, on by default | alpha 1.34 → beta 1.36 |

**Container-level (GA):** mutate `.spec.containers[*].resources` on a running pod (directly, or via Deployment/StatefulSet), no delete/recreate. Kubelet patches cgroups live where possible. Some decreases (memory limits under pressure) can still be deferred or refused for safety — check `status.conditions` (`PodResizePending` / `PodResizeInProgress`).

**Pod-level (beta, new in 1.36):** resizes the aggregate `.spec.resources` budget for pods using the pod-level resource model (shared pool across containers, useful for sidecar-heavy pods). Requires `PodLevelResources` + both resize gates + `NodeDeclaredFeatures`.

**Requirements:**
- cgroup v2 (v1 won't enforce pod-level limits correctly)
- CRI `UpdateContainerResources` support (containerd v2.0+, current CRI-O)
- `kubectl` ≥ 1.32 for the `--subresource resize` patch path

**Why it matters operationally:**
- VPA's `InPlaceOrRecreate` update mode (beta, on top of this) now actually avoids evicting pods for routine right-sizing — directly useful for the KubeVirt/Harvester VM-workload-adjacent pods and for AI/GPU workloads (Katib/Training Operator jobs) where restart cost is high.
- Also backs CPU startup-boost patterns (request more CPU at cold start, scale back after).

**Relevance to our stack:** RKE2 1.36.x already ships this. For customer engagements still pinned to RKE2 1.33/1.34, they get container-level GA resize but not the pod-level beta — flag this explicitly in any SoW that promises "sidecar-aware autoscaling," since that specifically needs 1.36.

---

## 3. Bottom line

Both features are safe to design into new air-gapped/sovereign RKE2 builds targeting 1.36. Two pre-flight checks before committing either to a customer architecture: node kernel ≥ 6.3 (user namespaces) and cgroup v2 + CRI version (pod-level resize). Neither is retrofittable without a node OS/kernel bump, so bake the check into discovery, not build.
