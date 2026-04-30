output "cluster_name" {
  value = google_container_cluster.gke.name
}

output "cluster_location" {
  value = google_container_cluster.gke.location
}

output "cluster_endpoint" {
  value     = google_container_cluster.gke.endpoint
  sensitive = true
}

output "artifact_repo" {
  description = "Fully-qualified Artifact Registry repo (region-docker.pkg.dev/PROJECT/REPO)."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.images.repository_id}"
}

output "api_sa_email" {
  description = "GSA the api KSA impersonates via Workload Identity. Wired into the KSA via iam.gke.io/gcp-service-account annotation."
  value       = google_service_account.api.email
}

output "worker_sa_email" {
  value = google_service_account.worker.email
}

output "api_lb_static_ip" {
  description = "Static external IP reserved for the api LoadBalancer Service. Pin via spec.loadBalancerIP."
  value       = google_compute_address.api_lb.address
}

output "db_connection_name" {
  value = google_sql_database_instance.pg.connection_name
}

output "db_private_ip" {
  value = google_sql_database_instance.pg.private_ip_address
}

output "redis_host" {
  value = google_redis_instance.cache.host
}

output "redis_port" {
  value = google_redis_instance.cache.port
}

output "web_url" {
  value = "https://storage.googleapis.com/${google_storage_bucket.web.name}/index.html"
}

output "web_bucket" {
  value = google_storage_bucket.web.name
}
