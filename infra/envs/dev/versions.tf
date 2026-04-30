terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend bucket name is `<project>-tf-state`. Set via `-backend-config`
  # at init time so the same code works across projects.
  #   terraform init -backend-config="bucket=ulys-dev-XXXXX-tf-state" -backend-config="prefix=envs/dev"
  backend "gcs" {}
}

provider "google" {
  project               = var.project
  region                = var.region
  user_project_override = true
  billing_project       = var.project
}
