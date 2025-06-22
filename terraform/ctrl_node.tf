# Upload cloud-init configuration to Proxmox as a snippet
resource "proxmox_virtual_environment_file" "ctrl_cloud_init_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  overwrite = false

  source_raw {
    # path = local_file.ctrl_processed_cloud_init.filename
    data  = templatefile("${path.module}/config/cloud_init_ctrl.tftpl", {
        hostname   = var.ctrl_hostname
        k8s_version = var.RKE2_VERSION
        ssh_keys = join("\n      - ", [trimspace(var.admin_ssh_public_key)])
        proxmox_host_ip = var.proxmox_host_ip
        GCP_LOGGING_KEY = local.rancher_credentials_json
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.MONITORED_RESOURCE_LOCATION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.ctrl_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
      })
    file_name = "cloud_init_ctrl.yaml"
  }
}

# Define the Proxmox Virtual Machine using BGP Proxmox Provider
resource "proxmox_virtual_environment_vm" "ctrl_rancher_vm" {
  name      = var.ctrl_hostname
  node_name = var.node_name
  stop_on_destroy = false
  on_boot = true

  cpu {
    cores   = 6
    sockets = 1
    type    = "host"     # ✅ Use host CPU model for full feature set
    numa    = true       # ✅ Enable NUMA for better memory locality
  }

  # Dummy blocks — minimum 1GB hugepages + unique fake CPU
  numa {
    device    = "numa0"
    cpus      = "0"
    memory    = 1024
    hostnodes = "0"
    policy    = "bind"
  }

  numa {
    device    = "numa1"
    cpus      = "1"
    memory    = 1024
    hostnodes = "1"
    policy    = "bind"
  }

  numa {
    device    = "numa2"
    cpus      = "2"
    memory    = 1024
    hostnodes = "2"
    policy    = "bind"
  }

  numa {
    device = "numa3"
    cpus   = "3-5"
    memory = 24576
    hostnodes = "3"
    policy = "bind"
  }

  memory {
    dedicated = 27648       # fixed RAM allocation in MiB
    hugepages = var.enable_hugepages ? var.hugepages_value : null
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.VM_DISK_STORAGE
    file_id      = "local:iso/${basename(var.vm_img)}"
    interface    = "scsi0"           # ✅ Required for iothread
    iothread     = true              # ✅ Improves disk performance
    discard      = "on"
    size         = 300
    file_format  = "raw"             # ✅ Fastest disk format
  }

  scsi_hardware = "virtio-scsi-single"  # ✅ Modern, efficient I/O controller

  boot_order = ["scsi0"]

  network_device {
    bridge   = "vmbr1"
    model    = "virtio"
    firewall = false             # ✅ Reduce overhead, firewalling not needed here
  }

  initialization {
    datastore_id = "local"
    interface    = "scsi1"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.ctrl_cloud_init_config.id
  }

  depends_on = [ proxmox_virtual_environment_vm.etcd_rancher_vm ]
}
