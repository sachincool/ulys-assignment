resource "google_sql_database_instance" "pg" {
  name             = "ulys-pg"
  region           = var.region
  database_version = "POSTGRES_15"

  # Set to true once a real prod env exists. Dev should be cheap to drop.
  deletion_protection = false

  depends_on = [google_service_networking_connection.psa]

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }
  }
}

resource "google_sql_database" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
  password = random_password.db.result
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-app-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_redis_instance" "cache" {
  name           = "ulys-redis"
  region         = var.region
  tier           = "BASIC"
  memory_size_gb = 1
  redis_version  = "REDIS_7_0"

  authorized_network = google_compute_network.vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  auth_enabled            = false
  transit_encryption_mode = "DISABLED"

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }

  depends_on = [google_service_networking_connection.psa]
}
