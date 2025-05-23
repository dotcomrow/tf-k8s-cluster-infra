# Upload cloud-init configuration to Proxmox as a snippet
resource "proxmox_virtual_environment_file" "work_cloud_init_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  overwrite = false

  source_raw {
    # path = local_file.ctrl_processed_cloud_init.filename
    data  = templatefile("${path.module}/config/cloud_init_work.tftpl", {
        hostname   = var.work_hostname
        k8s_version = var.RKE2_VERSION
        ssh_keys = join("\n      - ", [trimspace(var.admin_ssh_public_key)])
        proxmox_host_ip = var.proxmox_host_ip
        GCP_LOGGING_KEY = base64encode(trimspace(output.rancher_wif_credentials_json))
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.MONITORED_RESOURCE_LOCATION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.work_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        NVIDIA_DRIVER = var.NVIDIA_DRIVER
      })
    file_name = "cloud_init_work.yaml"
  }
}

# Define the Proxmox Virtual Machine using BGP Proxmox Provider
resource "proxmox_virtual_environment_vm" "work_rancher_vm" {
  name      = var.work_hostname
  node_name = var.node_name
  stop_on_destroy = false
  on_boot = true

  cpu {
    cores   = 18
    sockets = 3
    type    = "host"
  }

  memory {
    dedicated = 393216
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
    size         = 1275
    file_format  = "raw"
  }

  boot_order = ["scsi0"]

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  # Attach GPU using PCI passthrough
  hostpci {
    device = "hostpci0"
    mapping = "nvidia"
  }

  initialization {
    datastore_id = "local"
    interface = "scsi1"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.work_cloud_init_config.id
  }

  depends_on = [ proxmox_virtual_environment_vm.ctrl_rancher_vm ]
}
