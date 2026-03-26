terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    google = {
      source = "hashicorp/google"
    }
    google-beta = {
      source = "hashicorp/google-beta"
    }
  }
}

provider "proxmox" {
  endpoint = "https://${var.proxmox_host_ip}:8006/api2/json"
  username = var.proxmox_api_username
  password = var.proxmox_api_password
  insecure = true

  ssh {
    agent       = false
    private_key = var.proxmox_ssh_private_key
    username    = "root"
    dynamic "node" {
      for_each = [var.node_name]
      content {
        name    = var.node_name
        address = var.proxmox_host_ip
        port    = 22
      }
    }
  }
}

provider "google" {
  alias   = "infra"
  region  = var.region
  project = google_project.infra.project_id
}

provider "google-beta" {
  alias   = "infra"
  region  = var.region
  project = google_project.infra.project_id
}

provider "google" {
  region      = var.region
}

provider "google-beta" {
  region      = var.region
}
