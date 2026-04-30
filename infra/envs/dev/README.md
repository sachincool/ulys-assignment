# envs/dev

The only env in this repo (prod is described, not built — see top-level README).

## Initial apply (run from a laptop)

```bash
cd infra/envs/dev
terraform init \
  -backend-config="bucket=${PROJECT_ID}-tf-state" \
  -backend-config="prefix=envs/dev"
terraform apply \
  -var "project=${PROJECT_ID}" \
  -var "billing_account=${BILLING_ACCOUNT}"
```

The state bucket is created by `infra/bootstrap/`. Run that first.

## What Terraform owns vs. what manifests own

Terraform creates: VPC + secondary ranges + PSA + Cloud NAT, GKE
Autopilot cluster, Cloud SQL, Memorystore, Artifact Registry, runtime
GSAs + WI bindings + project IAM, Secret Manager secret + IAM,
static external IP, web bucket, billing budget, uptime check + alert.

Manifests own: Rollout/api, Deployment/worker, Services, NetworkPolicy,
KSAs (with `iam.gke.io/gcp-service-account` annotation referencing the
GSAs Terraform created), SecretProviderClass (referencing the secret
Terraform created), AnalysisTemplate. Applied by `kustomize build |
envsubst | kubectl apply -f -` from CI.

The split is deliberate: terraform plan stays clean across image
deploys. CI never runs `terraform apply`; ci-infra does that on
`infra/**` changes only.
