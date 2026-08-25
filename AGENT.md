# AGENT.md — Gateway API on RKE2 training

Instructions for an AI agent continuing work on this training material.

---

## What this is

A half-day (3h30–4h) workshop on the Kubernetes Gateway API, delivered by SUSE Consulting EMEA,
targeting Rancher/RKE2 environments.

## Access model — read this before editing anything

**Participants drive the entire lab through a kubeconfig from their own machine.** No SSH, no root,
no node filesystem access. This is a hard constraint, not a preference.

Consequences that are easy to get wrong:

- **Never** instruct a participant to write to `/var/lib/rancher/rke2/server/manifests/`. Lab 3
  applies the `HelmChartConfig` with `kubectl apply` instead — a `HelmChartConfig` is an ordinary
  namespaced CR, so this works and is the better GitOps habit. Only
  `10-provision-cluster.sh` touches the node.
- **Never** use `$NODE_IP`. Every HTTP call goes through `$GW_URL`, which is either Traefik's
  LoadBalancer address (when routable) or `http://127.0.0.1:8080` from
  `kubectl -n kube-system port-forward svc/traefik 8080:80`. `resolve_gw_url` in
  `lib/common.sh` picks automatically and prefers the real data path.
- The participant's `~/lab` git repo lives **on their workstation**, not the node.
- The kubeconfig is **cluster-admin**. Labs create namespaces and RBAC and use
  `--as=system:serviceaccount:...` impersonation, so a scoped credential fails partway through.
  Clusters are disposable; destroy them after the session.

### Open decision: one cluster each, or one shared cluster?

Everything is currently written for **one single-node cluster per participant**. If that changes to
a shared cluster, these break and must be reworked:

| Lab | What breaks on a shared cluster |
|---|---|
| 3 | Enabling the Gateway provider is cluster-wide. Becomes an instructor demo; participants only inspect. |
| 4, 7 | `demo` / `infra` / `team-a` / `team-b` collide. Needs per-participant prefixes — `common.sh` already reads `DEMO_NS`, `INFRA_NS`, `TENANT_A`, `TENANT_B` from the environment for exactly this. |
| 4.5, 2.3 | Impersonation and cluster-admin for many participants on one cluster is a different security posture. |
| Appendix A | Gateway `web` in `infra` is edited in place; two participants would fight over it. |

Ask before assuming. Do not silently convert one model to the other.

**Deliverables in this directory:**

| File | Audience | What it is |
|---|---|---|
| `01-slides-gateway-api-rke2.md` | all | Unified master Marp deck + interactive lab guide |
| `manifests/*.yaml` | all | Ready-to-use Kubernetes YAML manifests for all labs |
| `common.sh` | — | Shared helpers. Sourced, never executed. |
| `00-check-prereqs.sh` | participant | Tooling, cluster reachability, RBAC, Traefik, data path |
| `10-provision-cluster.sh` | **instructor, on the node, as root** | Builds the RKE2 cluster, emits a remote kubeconfig |
| `20-enable-gateway-api.sh` | instructor | Enables Traefik's Gateway provider (reset/recovery path for Lab 3) |
| `30-install-podinfo.sh` | either | Deploys the workload; `--emit-only` writes the YAML participants own |
| `40-validate-lab.sh` | instructor | Per-lab outcome checks; `--answers` harvests the ⚠ VERIFY values |
| `90-teardown.sh` | either | Removes lab resources; `--all` is guarded and destructive |
| `AGENT.md` | agent | This file |

`03-prepare-lab-vm.sh` was split into the numbered scripts above. Do not reintroduce a monolith.

---

## Load these skills first

Before editing the lab manual or the scripts, load both of these from the local checkout at
`~/src/anthropics/knowledge-work-plugins`:

| Skill | Path | Use it for |
|---|---|---|
| `engineering/documentation` | `~/src/anthropics/knowledge-work-plugins/engineering/skills/documentation/SKILL.md` | The lab manual, this file, and any README. Technical writing, runbooks, onboarding guides. |
| `operations/runbook` | `~/src/anthropics/knowledge-work-plugins/operations/skills/runbook/SKILL.md` | Step-by-step procedures for recurring tasks. The lab manual and the numbered scripts are runbooks structurally: preconditions, ordered steps, expected output, verification, rollback. |

Read the `SKILL.md`, and any files under a sibling `references/` directory, before writing. If a
skill ships a structural convention that conflicts with the house style in this file, **this file
wins** — but say so in your response rather than silently diverging.

If the checkout is missing, fetch it and say that you did:

```bash
git clone https://github.com/anthropics/knowledge-work-plugins ~/src/anthropics/knowledge-work-plugins
```

Skills deliberately **not** used here, so nobody re-litigates it: everything under `data/`,
`design/`, `sales/`, `marketing/`, `legal/`, `finance/`, `productivity/`. `design/` looks relevant
for the deck and is not — it is product design (accessibility, design systems, UX copy), not
presentation design.

## Non-negotiable constraints

1. **Traefik is the primary implementation.** On RKE2, Gateway API means Traefik — it is the
   packaged, supported path. Envoy Gateway and NGINX Gateway Fabric appear only as comparison
   (Appendix D, and two deck slides). Do not reverse this without an explicit instruction.

2. **Author is a SUSE Lead Architect delivering to customers.** Material must be technically
   honest, include real limitations, and never recommend an unsupported path without stating the
   support consequence.

3. **Tone: peer-level and direct.** No filler, no marketing language, no hedging where facts are
   known. The "honest downsides" and "when to stay on Ingress" slides are load-bearing — do not
   soften or remove them.

4. **Deck must render.** Verify with `marp --no-stdin 01-slides-gateway-api-rke2.md -o /tmp/x.html`
   after every edit. Do **not** pass `--html`.

5. **Labs are interleaved, not batched.** Each lab immediately follows the concept it proves.
   Do not move them to the end. The running order is load-bearing:

   | Lab | Sits after slide | Proves |
   |---|---|---|
   | 1 | *What Ingress gave us* | env works, ServiceLB works, participant owns the YAML |
   | 2 | *The annotation explosion* | rewrite pain, canary has no field, RBAC cannot separate personas |
   | 3 | *The resource model* | enable Gateway API, verify CRDs, GatewayClass appears |
   | 4 | *Status conditions* | Gateway/HTTPRoute handshake, typed rewrite, scoped RBAC |
   | 5 | *Traffic splitting* | weights in one object, header routing |
   | 6 | *Beyond HTTP* | GRPCRoute on the same Gateway |
   | 7 | *Who may attach* | tenant isolation, hostname gap, ReferenceGrant |

6. **One artifact, evolving, in git.** Everything lives in `~/lab/` under version control.
   Labs 1–2 build the Ingress era; Labs 4–7 build the Gateway API era. `git diff` between the two
   is the closing argument of the session (see "The session in one command" in the manual).
   Every lab ends with a commit. Do not break this.

5. **All YAML must parse.** See "Validation" below. Never ship an untested manifest.

---

## ⚠ Highest-priority open task: verify against a real VM

The Gateway API manifests are spec-standard and safe. The **Traefik- and RKE2-specific behaviours
were written from documentation, not from a live cluster.** Steps marked `⚠ VERIFY` in the lab
manual must be executed on a real RKE2 VM before delivery.

Provision a cluster, then harvest the answers mechanically:

```bash
# on the node, as root, once
./scripts/10-provision-cluster.sh --advertise <reachable-ip-or-dns>

# from anywhere, with the emitted kubeconfig
export KUBECONFIG=./gwapi-lab.kubeconfig
./scripts/00-check-prereqs.sh
./scripts/20-enable-gateway-api.sh
./scripts/30-install-podinfo.sh --with-grpc --with-tenants
./scripts/40-validate-lab.sh --answers      # prints most of the table below
```

`--answers` resolves entryPoint names, the GatewayClass name, the Gateway API bundle version, the
served `ReferenceGrant` versions, whether Ingress annotation weighting works, whether h2c is
honoured, and the status code for a denied cross-namespace reference.

The remainder still needs a human working through the manual:

| Ref | What to verify |
|---|---|
| Lab 1.2 | Is `https://stefanprodan.github.io/podinfo` reachable from the lab network? |
| Lab 2.1 | Middleware annotation naming (`demo-strip-shop@kubernetescrd`) works as written; and the failure mode when it is wrong. |
| **Lab 2.2** | **Highest value.** Does `traefik.ingress.kubernetes.io/service.weight` actually weight an Ingress canary? Likely **no** — Traefik wants a `TraefikService`. The lab is written to teach either outcome, but you must know which you will get. |
| Lab 2.3 | Confirm the `--as=system:serviceaccount:demo:dev` RBAC escalation demo behaves as described. |
| Lab 3.1 | Are Gateway API CRDs already present before enabling the provider? |
| Lab 3.4 | Exact `GatewayClass` name. Manual assumes `traefik`, uses `${GWCLASS:-traefik}`. |
| Lab 4.1 | Traefik entryPoint names and ports (`web`/`websecure` assumed). |
| Lab 4.4 | Does an invalid `URLRewrite.path.type` get rejected at admission (CRD enum validation)? |
| **Lab 6.1** | **Does Traefik honour `appProtocol: kubernetes.io/h2c` for a gRPC backend?** Without it, expect a protocol error rather than a routing error. |
| Lab 6.3 | Is `grpcurl` on the host, or must the `kubectl run` fallback be used? |
| Lab 6.4 | gRPC status code when the method match no longer matches. |
| Lab 7.5 | Exact HTTP status for an unauthorised cross-namespace backend. |
| Lab 7.6 | Is `ReferenceGrant` served as `v1`, `v1beta1`, or both? |
| Appendix B #8 | Condition + reason for a listener on a port with no Traefik entryPoint. |

**When reality differs from the manual, reality wins.** Update the manual, remove the `⚠ VERIFY`
marker, and record the observed value.

---

## Verified facts (current as of 2026-08-17)

Do not "correct" these from training-data priors — they were checked against primary sources.

**Gateway API upstream**
- Latest: **v1.6.1** (16 Jul 2026). v1.6.0 released 30 Jun 2026.
- v1.6: `TCPRoute` + `UDPRoute` → GA; experimental resources moved to a separate API group
  `gateway.networking.x-k8s.io` with an `X` prefix.
- v1.5 (27 Feb 2026): ListenerSet, TLSRoute, HTTPRoute CORS filter, client cert validation,
  certificate selection for TLS origination, ReferenceGrant → Standard.
- Standard channel cadence: 4 months.

**RKE2 / SUSE** — source: `docs.rke2.io/networking/networking_services#gateway-api`
- ingress-nginx went **EOL March 2026**; deprecated in RKE2 v1.36.
- **From v1.36 Traefik is the default ingress controller for new clusters.**
- Server config: `ingress-controller: traefik | none`.
- Gateway API requires Traefik. Enable via `HelmChartConfig` named `rke2-traefik` in `kube-system`
  with `providers.kubernetesGateway.enabled: true`.
- Traefik **v3.7.x → Gateway API v1.5**; v3.6.x → v1.4.
- Experimental channel CRDs must be installed separately + `experimentalChannel: true`.
- **Trap:** before the April 2026 releases (v1.33.11+rke2r1, v1.34.7+rke2r1, v1.35.4+rke2r1),
  disabling Traefik after enabling it **deletes the Gateway API CRDs and all Gateway/Route objects.**
- ServiceLB (klipper-lb) available via `--enable-servicelb`.
- Migration guide: `docs.rke2.io/reference/ingress_migration`.

**Traefik**
- Current docs support Gateway API v1.6.1: full HTTPRoute core + extended, `BackendTLSPolicy`,
  `GRPCRoute`, `TLSRoute` (Standard); `TCPRoute` (Experimental).
- Traefik `Middleware` CRDs plug into HTTPRoute via the standard `ExtensionRef` filter.
- Architectural note: **static infrastructure** — one Traefik, Gateways bind to existing
  entryPoints. Contrast with Envoy Gateway/NGF which provision per-Gateway infrastructure.

**Other**
- Envoy Gateway stable: v1.8.3 (v1.9.0-rc.1 published).
- podinfo lab image: `ghcr.io/stefanprodan/podinfo:6.7.0`, port 9898, configured via
  `PODINFO_UI_MESSAGE` / `PODINFO_UI_COLOR` env vars. Root path returns JSON with `.message`.

---

## Known gaps and judgement calls

- **Deck is English; delivery may be French.** Author works in both. Ask before translating.
- **Rancher UI has no first-class Gateway API view** as far as we know. Re-verify per delivery.
- **Lab 4.4 documents a genuine security gap:** listener `hostname` constrains the suffix but is
  not an ownership boundary. Mitigation is Kyverno / `ValidatingAdmissionPolicy`. This is
  deliberately taught, not hidden — do not remove it.
- **No GitOps/Fleet lab.** Cut for time; lives in Appendix C. The `~/lab` git history is already
  the right shape for it if the session ever grows to a full day.
- **Timing is untested with a real audience.** Budget: labs ~140 min, theory ~50 min, break 15 min,
  wrap ~20 min ≈ 3h25. Lab 2 and Lab 7 are the ones that overrun; Appendix B is the filler if a
  group finishes early.
- **Lab 2.2 is deliberately allowed to disappoint.** If Ingress annotation weighting does not work
  on Traefik, that *is* the lesson. Do not "fix" it into a `TraefikService` demo without keeping the
  point that you have left the Kubernetes API.
- **`kubectl explain` in Lab 3.3 and 4.4 is the single best demo in the deck.** It is the whole
  typed-vs-annotation argument in one command. Do not cut it for time.
- **Deck slide 3 ("Your environment") uses `_class: lab`** and states Gateway API is not yet enabled.
  If you change the prep script to pre-enable it, that slide and Lab 3 both need updating.

---

## Validation — run after every change

```bash
# 1. Deck renders (49 slides expected, notes in bespoke-marp-note containers)
marp --no-stdin 01-slides-gateway-api-rke2.md -o /tmp/deck.html

# 2. Every script parses
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" || echo "SYNTAX FAIL $f"; done

# 3. Generated manifests are valid without touching a cluster
scripts/30-install-podinfo.sh --emit-only /tmp/labyaml
python3 -c "
import yaml, glob
for f in sorted(glob.glob('/tmp/labyaml/*.yaml')):
    print(f, '->', [d['kind'] for d in yaml.safe_load_all(open(f)) if d])"

# 4. Scripts fail cleanly with no cluster (expect a single [FAIL] line, no traceback)
for s in 00-check-prereqs 20-enable-gateway-api 40-validate-lab 90-teardown; do
  KUBECONFIG=/nonexistent scripts/$s.sh 2>&1 | tail -2
done

# 5. All manifests in manifests/ parse + all kubectl patches in slides are valid JSON
python3 - <<'PY'
import re, json, glob
t = open('01-slides-gateway-api-rke2.md').read()
bad = 0
for p in re.findall(r"-p\s+'(\[.*?\])'", t, re.S) + \
         re.findall(r"--type=merge\s+\\?\s*\n?\s*-p\s+'(\{.*?\})'", t, re.S):
    try: json.loads(p)
    except Exception as e: print(f"PATCH FAIL: {e}"); bad += 1
print("OK" if not bad else f"{bad} failures")
PY
```

Slide density check (flags slides likely to overflow 16:9):

```bash
python3 - <<'PY'
import re
t = open('01-slides-gateway-api-rke2.md').read()
for i, s in enumerate(t.split('\n---\n')[2:], 1):
    s = re.sub(r'<!--.*?-->', '', s, flags=re.S)
    lines = [l for l in s.split('\n') if l.strip()]
    cl = sum(len(b.split('\n')) for b in re.findall(r'```[a-z]*\n(.*?)```', s, re.S))
    if (len(lines)-cl) + cl*0.72 > 24:   # ~24 is the 16:9 overflow threshold at 25px base
        print("DENSE:", i, next((l.strip('# ') for l in lines if l.startswith('#')), '?'))
PY
```

---

## Export

```bash
marp --no-stdin 01-slides-gateway-api-rke2.md -o deck.html        # speaker view: press P
marp --no-stdin 01-slides-gateway-api-rke2.md --pdf -o deck.pdf
marp --no-stdin 01-slides-gateway-api-rke2.md --pptx -o deck.pptx
```

PDF/PPTX need Chromium available to marp-cli.

---

## Style rules for edits

- **Deck:** `#` per slide, `---` separators, `<!-- _class: lead|divider|lab -->` for section
  slides. Presenter notes are HTML comments — they land in the speaker-note container, never on
  the slide. SUSE palette is defined in the frontmatter `style:` block: jungle `#0C322C`,
  green `#30BA78`, mint `#90EBCD`, waterhole `#2453FF`, persimmon `#FE7C3F`.
- **Lab manual:** every lab states Time + the slide it follows + Objective; commands are
  copy-pasteable heredocs writing into `~/lab/`; every lab ends with a Checkpoint and a git commit.
  Unverified claims carry `⚠ VERIFY`.
- **Lab file naming** in `~/lab/` is ordered by prefix: `01-` `02-` podinfo/Ingress era,
  `09-` HelmChartConfig, `10-`–`12-` Gateway era, `20-`–`21-` gRPC, `30-`–`31-` multi-tenancy,
  `40-` TLS. Keep the gaps.
- **Scripts:** numbered by execution order with gaps (`00`, `10`, `20`, `30`, `40`, `90`). Each one
  opens with a comment block stating **Audience**, **Runs on**, and what it needs. Source
  `lib/common.sh`; do not duplicate logging or the `check` helper. Use `check` for required
  conditions and `soft_check` for optional tooling, then end with `summary` so the exit code is
  meaningful. Destructive actions require a typed confirmation, not a `-y` flag.
- **`lib/common.sh` reads namespaces from the environment** (`DEMO_NS`, `INFRA_NS`, `TENANT_A`,
  `TENANT_B`). Keep it that way — it is the seam for a shared-cluster variant.
- **Never** invent a version number, CRD field, or status reason. Search and cite, or mark it
  `⚠ VERIFY`.

---

## Useful sources

- `docs.rke2.io/networking/networking_services#gateway-api` — the authoritative RKE2 answer
- `docs.rke2.io/reference/ingress_migration` — ingress-nginx → Traefik
- `doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/`
- `doc.traefik.io/traefik/reference/routing-configuration/kubernetes/gateway-api/`
- `gateway-api.sigs.k8s.io` — spec, concepts, security model
- `gateway-api.sigs.k8s.io/implementations/` — conformance reports; check before recommending
- `github.com/jpetazzo/container.training` — slides **CC BY 4.0**, code Apache 2.0. Reusable
  commercially with attribution. `prepare-labs/` is worth mining for VM provisioning.
