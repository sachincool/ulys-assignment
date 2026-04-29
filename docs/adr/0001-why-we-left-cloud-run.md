# ADR 0001: Why we left Cloud Run for GKE Standard

**Status:** Accepted (2026-04-30)

## Context

The take-home version of this product shipped on Cloud Run. It worked. It
also took **eleven deploy iterations** to land green, with each failure
isolating exactly one operational gotcha. Nine of those gotchas were
GCP-platform-level (API enablement order, billing-IAM scope, currency
mismatch, Cloud SQL provisioning lag, etc.) and would have hit us on any
GCP runtime. Two were Cloud-Run-specific:

1. **Cloud Run's edge unconditionally intercepts `/healthz`.** External
   GET `/healthz` returned Google's branded 404 with no `Server: Google
   Frontend` header — even when the container had a `/healthz` handler
   that responded 200 to internal startup probes. The fix was to use
   `/livez` for the public liveness path, registering `/healthz` only for
   spec compliance with the assignment.
2. **`egress = PRIVATE_RANGES_ONLY` routes `*.run.app` over the public
   internet.** Combined with the worker's `INGRESS_INTERNAL_ONLY`, this
   silently broke api → worker calls (the worker rejected the public-
   internet origin with a 404). The fix was `egress = ALL_TRAFFIC` so
   api → worker stays inside the VPC connector.

Plus one more pipeline-level surprise:

3. **`gcloud run services update-traffic --to-revisions` strips the
   canary tag** as a side effect, killing the tagged URL the smoke test
   depended on. The fix was to drop the live-traffic shift entirely and
   smoke against the 0%-traffic tagged URL.

These aren't *bugs*. They're emergent behaviour from a managed runtime
that papers over network and routing details we eventually need explicit
control over.

## Decision

Move to **GKE Standard, zonal, single zone**. Apply best practices
explicitly (Workload Identity, NetworkPolicy, shielded nodes, private
control plane, release channel, auto-repair/upgrade). Service-to-service
mTLS via Linkerd. Canary via Flagger on Prometheus SLOs.

The reason isn't "Cloud Run is bad". It's "Cloud Run's abstractions hide
exactly the things we want to reason about explicitly":

- Path routing (we now own it via Ingress + BackendConfig)
- Pod-to-pod reachability (NetworkPolicy + Linkerd AuthorizationPolicy)
- Identity (KSA → GSA Workload Identity, mTLS-authenticated KSA peers)
- Rollout shape (Flagger Canary CR, not gcloud subcommands)
- Release substrate (Argo CD reconciling a manifest repo)

## Consequences

### Positive

- Every deploy step is declarative and reviewable in `git log` of the
  manifest repo.
- Failures show up in `kubectl describe` with full context (pod state,
  events, previous container logs), not in stitched-together gcloud +
  Cloud Logging queries.
- The cluster is the same shape as anywhere we'd run K8s — including
  on-prem, AWS, or the developer's laptop with `kind`.
- We get HPA, VPA, NetworkPolicy, mesh, sidecars, init containers,
  CronJobs without further architecture changes.

### Negative

- Higher idle cost (~$70-90/mo dev floor vs $50/mo on Cloud Run).
- More moving parts to operate (cluster upgrades, Argo CD, Flagger,
  Linkerd, ESO, OTel collector). All managed via Argo CD + manifest
  repo, so the operational surface is "review a PR", but it's still
  more parts than Cloud Run.
- Onboarding cost for engineers who haven't touched K8s before. Mitigation:
  the runbook in `runbooks/` is the only escape hatch they need.

### Neutral

- Both runtimes solve the assignment. The choice is about what comes
  after the assignment.

## Evidence — the 9-failure iteration table from the take-home

| # | broke at | root cause |
|---|---|---|
| 1 | first push | repo vars not set yet (race with `gh variable set`) |
| 2 | `tf init` | `iamcredentials.googleapis.com` not enabled |
| 3 | `tf apply` | `iam.googleapis.com` not enabled + deployer SA missing `billing.user` on the billing account |
| 4 | `tf apply` | budget currency `USD` ≠ billing-account currency `INR`; worker memory `256Mi` below Cloud Run v2 floor when CPU is always allocated |
| 5 | smoke | `update-traffic --to-revisions` strips the canary tag → tagged URL 404 |
| 6 | smoke | Cloud Run reserves `/healthz` at the edge unconditionally |
| 7 | (cancelled mid-flight) | caught the wrong-probe-path issue while running |
| 8 | `tf init` | stale state lock from the cancelled run #7 |
| 9 | smoke | api `egress=PRIVATE_RANGES_ONLY` routes `*.run.app` over public internet; worker `ingress=INTERNAL_ONLY` rejects it |
| 10 | smoke | smoke script still polled `/healthz` for warm-up after the probe-path move |
| 11 | green | — |

Issues 5, 6, 9, and 10 are the ones GKE eliminates. The other seven would
have hit a GKE deploy too, in different forms.

## References

- [`smoke.sh`](https://github.com/sachincool/ulys-assignment/blob/main/scripts/smoke.sh)
  in the take-home repo — the canonical writeup of the `/healthz` edge
  interception.
- [`terraform/cloud_run.tf`](https://github.com/sachincool/ulys-assignment/blob/main/terraform/cloud_run.tf)
  for the `egress=ALL_TRAFFIC` decision and the `lifecycle.ignore_changes`
  workaround that made the canary tag work at all.
