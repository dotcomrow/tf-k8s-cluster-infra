# Upload cloud-init configuration to Proxmox as a snippet
resource "proxmox_virtual_environment_file" "srvr_cloud_init_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  overwrite = false

  source_raw {
    # path = local_file.ctrl_processed_cloud_init.filename
    data  = templatefile("${path.module}/config/cloud_init_srvr.tftpl", {
        hostname   = var.srvr_hostname
        k8s_version = var.RKE2_VERSION
        ssh_keys = join("\n      - ", [trimspace(var.admin_ssh_public_key)])
        proxmox_host_ip = var.proxmox_host_ip
        RANCHER_HOSTNAME = var.RANCHER_HOSTNAME
        RANCHER_DOMAIN = var.RANCHER_DOMAIN
        GITHUB_AUTH_VAL = var.GITHUB_AUTH_VAL
        GITHUB_CLIENT_ID = var.GITHUB_CLIENT_ID
        GITHUB_CLIENT_SECRET = var.GITHUB_CLIENT_SECRET
        GCP_LOGGING_KEY = base64encode(trimspace(var.GCP_LOGGING_KEY))
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.MONITORED_RESOURCE_LOCATION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.srvr_hostname
        GITHUB_ORG = var.GITHUB_ORG
        OAUTH2_PROXY_COOKIE_SECRET = var.OAUTH2_PROXY_COOKIE_SECRET
        KONG_MANAGER_OAUTH2_CLIENT_ID = var.KONG_MANAGER_OAUTH2_CLIENT_ID
        KONG_MANAGER_OAUTH2_CLIENT_SECRET = var.KONG_MANAGER_OAUTH2_CLIENT_SECRET
        KONG_MANAGER_GITHUB_AUTH_TEAM = var.KONG_MANAGER_GITHUB_AUTH_TEAM
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        FLEET_REPO_POST_INSTALL_KEY = base64encode(trimspace(var.FLEET_REPO_POST_INSTALL_KEY))
        ARGOCD_REPO_POST_INSTALL_KEY = base64encode(trimspace(var.ARGOCD_REPO_POST_INSTALL_KEY))
        ARGOCD_GITHUB_CLIENT_ID = var.ARGOCD_GITHUB_CLIENT_ID
        ARGOCD_GITHUB_CLIENT_SECRET = var.ARGOCD_GITHUB_CLIENT_SECRET
      })
    file_name = "cloud_init_srvr.yaml"
  }
}

# Define the Proxmox Virtual Machine using BGP Proxmox Provider
resource "proxmox_virtual_environment_vm" "srvr_rancher_vm" {
  name      = var.srvr_hostname
  node_name = var.node_name
  stop_on_destroy = false
  on_boot = true

  cpu {
    cores   = 4
    sockets = 2
    type    = "host"
  }

  memory {
    dedicated = 28672
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.VM_DISK_STORAGE
    file_id      = "local:iso/${basename(var.vm_img)}"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 200
    file_format  = "raw"
  }

  boot_order = ["scsi0"]

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  initialization {
    datastore_id = "local"
    interface = "scsi1"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.srvr_cloud_init_config.id
  }

  depends_on = [ null_resource.download_iso ]
}
