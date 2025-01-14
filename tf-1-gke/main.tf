terraform {
  required_version = "~> 1.5"

  required_providers {

    google = {
      source  = "hashicorp/google"
      version = "~> 4.8"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 4.8"
    }

  }
}

provider "google" {
  project = local.project
  region  = local.region
}

provider "google-beta" {
  project = local.project
  region  = local.region
}

locals {
  config = yamldecode(file("${path.module}/../config.yaml"))

  project              = local.config.project
  region               = local.config.region
  zones                = local.config.zones
  cluster_name         = local.config.cluster_name
  gke_region_subnet    = local.config.gke_network.region_subnet
  gke_service_subnet   = local.config.gke_network.service_subnet
  gke_pod_subnet       = local.config.gke_network.pod_subnet
  control_plane_subnet = local.config.gke_network.control_plane_subnet
  dns_zone             = local.config.dns_zone
  authorized_networks  = local.config.authorized_networks
}
