# ADR 0001 — GKE Autopilot over Cloud Run

- **Status**: Accepted
- **Date**: 2026-04-28
- **Supersedes**: an earlier draft of this stack that ran api + worker on
  Cloud Run (a few stale code comments referencing "Cloud Run URL"
  survived the migration; rewritten to reflect the GKE design and to
  describe the Cloud Run path as a future option, not the current one).

## Context

The brief asks for:

1. Two services (api, worker) plus a static `web`.
2. A canary deploy with smoke tests, automatic promote, automatic
   rollback on failure.
3. `worker` must reject unauthenticated traffic from anywhere except
   `api`.
4. Realistic monthly spend $5–15 idle, with a Cloud Billing budget.
5. Workload Identity Federation for CI — no long-lived JSON keys.

Both Cloud Run and GKE Autopilot can clear (1)–(5). The decision is
about which is cheaper to operate, lower in LOC, and closer to the
canary + auth model the brief actually rewards.

## Options considered

### A. Cloud Run (the earlier draft)

- `api` and `worker` as two Cloud Run services. `worker` is internal-only
  (`--ingress=internal`) with `roles/run.invoker` granted to the api GSA;
  api calls worker with `idtoken.NewClient(ctx, workerURL)`.
- Canary via Cloud Run **traffic splits** (`gcloud run services
  update-traffic --to-revisions REV=10`).
- Smoke tests = a `curl` step in CI between the 10% and 100% splits.

**Why we walked away:**

- **No real analysis-gated canary.** Cloud Run's traffic split is a
  weight knob; rollback is "CI noticed `curl` failed and ran another
  `update-traffic` to put 100% back on the previous revision". That's a
  rolling deploy with a manual undo, not the brief's "deploy a canary,
  run smoke tests, promote or roll back automatically". Argo Rollouts
  on GKE gives a real `Rollout` controller with `AnalysisTemplate` Job
  probes between weight steps and an automatic abort wired to the
  AnalysisRun's `Failed` state — public traffic exposure to a bad
  revision is bounded by `weight × interval` (~10% × ~30s here), not
  "until CI's next step runs".
- **Cold-start tax on the canary smoke test.** A min-instances=0 canary
  revision needs warming before `curl /readyz` is meaningful, or you
  pay min-instances=1 on every revision.
- **Two LoadBalancer-equivalent surfaces, not one.** Each Cloud Run
  service ships with its own front door, so `worker` ends up with a
  public hostname that is then locked down with `--ingress=internal` +
  IAM. On GKE the worker is a `ClusterIP` with no public surface at
  all; that's strictly less to mis-configure.
- **The api ↔ worker auth story is identical.** Same `idtoken.NewClient`
  on the caller, same Google JWKs validation on the callee, same WI
  identity behind both. So Cloud Run's "front door auth via
  `roles/run.invoker`" doesn't buy us anything we can't reproduce in
  ~30 LOC of middleware (which we already needed for the in-cluster
  case, since we layer NetworkPolicy underneath it).

### B. GKE Autopilot (chosen)

- Single zonal Autopilot cluster, `us-central1-a`. Free control plane
  (first zonal cluster per project), per-pod billing scales to ~$0
  idle.
- Canary via Argo Rollouts: `setWeight: 10 → 50 → 100` with
  `AnalysisTemplate` running `curl /readyz` Jobs between steps;
  AnalysisRun `Failed` → Rollout `Aborted` → traffic stays 100% on the
  prior stable revision → CI gate (`kubectl argo rollouts status api`)
  exits non-zero → job fails.
- Worker = `ClusterIP` Service with `NetworkPolicy`
  `worker-ingress-from-api-only` (Dataplane V2 / Cilium enforcement)
  **plus** Google ID-token validation. Two independent layers, either
  alone refuses any other pod's calls.
- WIF unchanged: `gh-deployer-dev` GSA, `attribute_condition` pinning
  trust to `repository == ulys-assignment AND environment == dev`.

### C. GKE Standard

- Rejected. Same control-plane fee, but we'd own node-pool sizing,
  upgrades, and a long list of security defaults Autopilot turns on
  for us (Workload Identity, Shielded Nodes, NetworkPolicy enforcement,
  image streaming, restricted Pod Security Standards). The take-home
  doesn't ship any DaemonSets or per-pool spot pricing, the two
  knobs that pay for Standard's friction.

## Decision

Run api + worker on **GKE Autopilot**. Argo Rollouts owns the canary
mechanics; CI's job is to apply the new image and gate on
`kubectl argo rollouts status`. NetworkPolicy + Google ID tokens are
the two layers protecting worker.

## Consequences

**Accepted now:**

- Memorystore alone costs ~$35/mo whether or not anything calls it,
  pushing the dev idle bill to ~$55–60/mo. The brief's $5–15 target only
  fits if we `terraform destroy` between sessions; `just down` does that
  in one command. A $20 budget alert is provisioned in
  `infra/envs/dev/ops.tf`.
- Argo Rollouts controller adds ~30m CPU / 100Mi RAM. Worth it: the
  `Rollout` resource is identical to a `Deployment` minus the `strategy`
  block, so no app code is canary-aware.
- Master authorized networks are open to `0.0.0.0/0` for dev
  convenience; prod tightens to CI runner CIDR + bastion.

**Deferred to production** — see the
[README "What's deferred for production"](../../README.md#whats-deferred-for-production)
section, which is the canonical list. Highlights:

- Regional control plane (~$73/mo, HA across all 3 zones).
- Linkerd mesh for transport-layer mTLS; ID-token check stays as the
  application-layer signal that survives a mesh outage.
- Global HTTPS LB + Cloud Armor + managed cert + custom domain,
  replacing the current L4 LoadBalancer Service on a static external IP.
- BinAuthz + cosign-signed digests with KMS attestor.
- Cloud SQL IAM auth via the Auth Proxy; `STANDARD_HA` Memorystore with
  AUTH + transit encryption.
- Argo CD + a split manifest repo, replacing the current in-CI
  `kubectl apply -k` once we're at 2+ environments or 3+ teams.
- Prometheus-backed `AnalysisTemplate` (`http_5xx_rate < 0.01` on real
  canary traffic) instead of the `curl /readyz` Job probe.

## When we'd revisit

- **Per-service traffic patterns diverge.** If `worker` becomes a bursty
  CPU-bound transformer that idles flat the rest of the time, a Cloud
  Run worker behind the same `idtoken.NewClient` call site is a
  one-knob migration — see the comment in `apps/api/internal/server/
  handlers.go::callWorker`. The api stays on GKE for the steady-state
  baseline + the canary controller.
- **Steady fleet >5 services.** Cloud Run's per-service pricing crosses
  GKE Autopilot's per-pod pricing somewhere around there for our size
  pods.
- **Compliance forces multi-region active/active.** GKE multi-cluster +
  Multi Cluster Ingress is a heavier lift than two Cloud Run regions
  behind a global HTTPS LB; that's the scenario where Cloud Run's
  simpler regional story actually wins.
