# ulys — plug-and-play spin up / spin down.
#
# Pre-reqs (one-time on the operator's laptop):
#   brew install pulumi pnpm gcloud kubectl helm gh
#   gcloud auth login
#   gcloud auth application-default login
#
# Usage:
#   make up      ENV=dev PROJECT_ID=ulys-dev-XXXXX BILLING_ACCOUNT=01XXXX-XXXX  GITHUB_REPO=owner/ulys-prod  MANIFEST_REPO=owner/ulys-manifests
#   make down    ENV=dev PROJECT_ID=ulys-dev-XXXXX
#
# `up` orchestrates: GCP project create+billing → enable APIs → bootstrap
# stack → env stack → install Argo CD root Application → wait for Healthy.
# `down` runs `pulumi destroy` on the env stack and the bootstrap stack,
# then `gcloud projects delete`.
#
# Everything else flows through GitOps: image bumps go via `ci-app.yml`,
# manifest commits go via the manifest-bump PR, Argo CD reconciles.

ENV              ?= dev
PROJECT_ID       ?= $(error PROJECT_ID is required)
BILLING_ACCOUNT  ?= $(error BILLING_ACCOUNT is required)
GITHUB_REPO      ?= sachincool/ulys-assignment
MANIFEST_REPO    ?= sachincool/ulys-manifests
REGION           ?= us-central1

# Use a stable per-env passphrase. In CI/prod, pull from `pulumi config env`.
export PULUMI_CONFIG_PASSPHRASE = ulys-$(ENV)-passphrase

.PHONY: up down bootstrap stack apps argocd verify destroy clean

up: bootstrap stack argocd verify
	@echo
	@echo "✅ ulys-$(ENV) is up. Argo CD is reconciling from $(MANIFEST_REPO)."
	@echo "   - Cluster:  $$(cd infra/stacks/$(ENV) && pulumi stack output clusterName)"
	@echo "   - api URL:  http://$$(kubectl -n ulys get ingress api -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):80"
	@echo "   - argocd:   kubectl -n argocd port-forward svc/argo-cd-server 8080:80"

bootstrap:
	@echo "==> create project $(PROJECT_ID) (idempotent)"
	@gcloud projects describe $(PROJECT_ID) >/dev/null 2>&1 || \
	  gcloud projects create $(PROJECT_ID) --name=ulys-$(ENV)
	@gcloud billing projects link $(PROJECT_ID) --billing-account=$(BILLING_ACCOUNT) >/dev/null
	@gcloud config set project $(PROJECT_ID) >/dev/null
	@gcloud auth application-default set-quota-project $(PROJECT_ID) 2>/dev/null
	@echo "==> enable APIs"
	@gcloud services enable \
	  iam.googleapis.com iamcredentials.googleapis.com \
	  cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
	  compute.googleapis.com container.googleapis.com \
	  sqladmin.googleapis.com redis.googleapis.com \
	  servicenetworking.googleapis.com artifactregistry.googleapis.com \
	  secretmanager.googleapis.com cloudkms.googleapis.com cloudbilling.googleapis.com \
	  storage.googleapis.com monitoring.googleapis.com logging.googleapis.com \
	  cloudtrace.googleapis.com binaryauthorization.googleapis.com containeranalysis.googleapis.com \
	  --project=$(PROJECT_ID) >/dev/null
	@echo "==> infra/bootstrap (state bucket + WIF + curated deployer SA)"
	@cd infra && pnpm install --silent
	@cd infra/bootstrap && \
	  pulumi login file://./pulumi-state >/dev/null 2>&1 || true; \
	  pulumi stack select $(ENV)-bootstrap >/dev/null 2>&1 || pulumi stack init $(ENV)-bootstrap >/dev/null; \
	  pulumi config set gcp:project $(PROJECT_ID) && \
	  pulumi config set gcp:region $(REGION) && \
	  pulumi config set ulys-bootstrap:githubRepo $(GITHUB_REPO) && \
	  pulumi up --yes --skip-preview
	@echo "==> wire GitHub Actions vars on $(GITHUB_REPO)"
	@$(eval WIF := $(shell cd infra/bootstrap && pulumi stack output wifProviderResource))
	@$(eval DEPLOYER := $(shell cd infra/bootstrap && pulumi stack output deployerSaEmail))
	@$(eval STATE_BUCKET := $(shell cd infra/bootstrap && pulumi stack output stateBucketName))
	@gh variable set GCP_PROJECT_ID_$(shell echo $(ENV) | tr a-z A-Z) -b "$(PROJECT_ID)" -R $(GITHUB_REPO)
	@gh variable set WIF_PROVIDER_$(shell echo $(ENV) | tr a-z A-Z)   -b "$(WIF)"        -R $(GITHUB_REPO)
	@gh variable set DEPLOYER_SA_$(shell echo $(ENV) | tr a-z A-Z)    -b "$(DEPLOYER)"   -R $(GITHUB_REPO)
	@gh variable set GCP_REGION  -b "$(REGION)" -R $(GITHUB_REPO) || true

stack:
	@echo "==> infra/stacks/$(ENV) (cluster + DB + cache + IAM)"
	@cd infra/stacks/$(ENV) && \
	  pulumi login gs://$(PROJECT_ID)-pulumi-state >/dev/null && \
	  pulumi stack select $(ENV) >/dev/null 2>&1 || pulumi stack init $(ENV) >/dev/null; \
	  pulumi config set gcp:project $(PROJECT_ID) && \
	  pulumi config set gcp:region $(REGION) && \
	  pulumi up --yes --skip-preview

argocd:
	@echo "==> kube credentials + Argo CD bootstrap"
	@$(eval CLUSTER_NAME := $(shell cd infra/stacks/$(ENV) && pulumi stack output clusterName))
	@$(eval CLUSTER_LOC := $(shell cd infra/stacks/$(ENV) && pulumi stack output clusterLocation))
	@gcloud container clusters get-credentials $(CLUSTER_NAME) --location=$(CLUSTER_LOC) --project=$(PROJECT_ID) >/dev/null
	@kubectl apply -f https://raw.githubusercontent.com/$(MANIFEST_REPO)/main/argocd-applications/root.yaml
	@kubectl apply -f https://raw.githubusercontent.com/$(MANIFEST_REPO)/main/argocd-applications/platform-$(ENV).yaml
	@echo "Argo CD is reconciling. Run 'make verify' to wait until apps are Healthy."

verify:
	@echo "==> waiting for apps-$(ENV) Healthy (timeout 8m)"
	@kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/apps-$(ENV) --timeout=8m

down:
	@echo "==> tear down env stack ($(ENV))"
	@cd infra/stacks/$(ENV) && pulumi destroy --yes --skip-preview || true
	@echo "==> tear down bootstrap"
	@cd infra/bootstrap && pulumi stack select $(ENV)-bootstrap >/dev/null 2>&1 && \
	  pulumi destroy --yes --skip-preview || true
	@echo "==> delete project (immediate billing stop, 30d undelete window)"
	@gcloud projects delete $(PROJECT_ID) --quiet || true

clean:
	@cd infra && rm -rf node_modules
	@cd infra/bootstrap && rm -rf pulumi-state .pulumi
