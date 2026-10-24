terraform {
  # terraform_data needs 1.4+, replace_triggered_by needs 1.2+.
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.50"
    }
  }

  # Partial backend configuration. The bucket name is supplied at init time:
  #   terraform init -backend-config=backend.hcl
  # backend.hcl is git-ignored. See backend.hcl.example.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
