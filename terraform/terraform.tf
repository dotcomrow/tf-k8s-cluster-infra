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
  endpoint  = var.proxmox_api_endpoint
  username = var.proxmox_api_username
  password = var.proxmox_api_password
  insecure  = true
  ssh {
    agent = false
    private_key = var.proxmox_ssh_private_key
    username= "root"
    dynamic "node" {
      for_each = [var.node_name]
      content {
        name    = var.node_name
        address = "${var.PROXMOX_HOSTNAME}.${var.RANCHER_DOMAIN}"
        port    = var.PROXMOX_SSH_PORT
      }
    }
  }
}

provider "google" {
  region      = var.region
}

provider "google-beta" {
  region      = var.region
}