resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "ulys"
  format        = "DOCKER"
  description   = "ulys api + worker images"

  depends_on = [google_project_service.services]
}

# GKE Autopilot — opinionated 2026 default. Workload Identity, Shielded
# Nodes, NetworkPolicy, image streaming all on by default. Autopilot has a
# flat ~$0.10/hr cluster management fee (~$73/mo) since late 2023 — there
# is no longer a "first zonal cluster free" tier. Zonal location keeps the
# control plane single-AZ which is the cheaper SLA tier and matches the
# dev blast-radius story; prod flips this to var.region for regional HA.
resource "google_container_cluster" "gke" {
  name     = "ulys-gke"
  location = var.zone
  project  = var.project

  enable_autopilot    = true
  deletion_protection = false

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Open control plane to anywhere for the take-home; prod tightens this
  # to a CI runner CIDR + bastion.
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "dev-only-do-not-use-in-prod"
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # The GKE-managed Secret Manager CSI add-on (used by SecretProviderClass
  # consumers with `provider: gke`) is enabled out-of-band by `just platform`
  # via `gcloud container clusters update --enable-secret-manager`. The
  # equivalent Terraform field (`secret_manager_config`) lives in google
  # provider v6.x; staying on v5.x for now to keep blast radius small.

  depends_on = [google_project_service.services]
}

# Per-service runtime identities. No JSON keys, ever — KSAs impersonate
# these via Workload Identity (binding below).
resource "google_service_account" "api" {
  account_id   = "ulys-api"
  display_name = "WI runtime SA: api"
}

resource "google_service_account" "worker" {
  account_id   = "ulys-worker"
  display_name = "WI runtime SA: worker"
}

locals {
  api_project_roles = [
    "roles/cloudsql.client",
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
  worker_project_roles = [
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

resource "google_project_iam_member" "api" {
  for_each = toset(local.api_project_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "worker" {
  for_each = toset(local.worker_project_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_secret_manager_secret_iam_member" "api_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

# Workload Identity bindings — the KSA `ulys/api` impersonates the GSA
# `ulys-api`, and likewise for worker. The KSA's metadata.annotation
# `iam.gke.io/gcp-service-account` (set in the manifest) is what wires it
# at the cluster side; this binding is the GCP side.
resource "google_service_account_iam_member" "api_wi" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[ulys/api]"

  depends_on = [google_container_cluster.gke]
}

resource "google_service_account_iam_member" "worker_wi" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[ulys/worker]"

  depends_on = [google_container_cluster.gke]
}

# Static external IP for the api LoadBalancer Service. The Service in
# manifests/ pins to it via `loadBalancerIP:` so the URL is stable across
# pod cycles, which the uptime check + the web bucket's API_URL rely on.
resource "google_compute_address" "api_lb" {
  name         = "api-lb"
  project      = var.project
  region       = var.region
  address_type = "EXTERNAL"

  depends_on = [google_project_service.services]
}
