terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }

  # Local backend on purpose: this stack creates the GCS bucket that
  # everything else uses as its remote backend. Bottom-turtle bootstrap.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "google" {
  project = var.project
  region  = var.region
}
