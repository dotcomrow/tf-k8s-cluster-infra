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
        GCP_LOGGING_KEY = local.rancher_credentials_json
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.MONITORED_RESOURCE_LOCATION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.work_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        NVIDIA_DRIVER = var.NVIDIA_DRIVER
        WORK_NODE_MAX_PODS = var.WORK_NODE_MAX_PODS
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
    type    = "host"     # ✅ Best performance
    numa    = true       # ✅ Enable NUMA for >1 socket
  }

  numa {
    device = "numa0"
    cpus   = "0-5"
    memory = 124928  # 122 GiB in MiB
    hostnodes = "0"
    policy    = "bind"
  }

  numa {
    device = "numa1"
    cpus   = "6-11"
    memory = 126976  # 124 GiB in MiB
    hostnodes = "1"
    policy    = "bind"
  }

  numa {
    device = "numa2"
    cpus   = "12-17"
    memory = 126976  # 124 GiB in MiB
    hostnodes = "2"
    policy    = "bind"
  }

  memory {
    dedicated = 378880       # fixed RAM allocation in MiB
    hugepages = var.enable_hugepages ? var.hugepages_value : null
  }
  
  agent {
    enabled = true
  }

  disk {
    datastore_id = var.VM_DISK_STORAGE
    file_id      = "local:iso/${basename(var.vm_img)}"
    interface    = "scsi0"            # ✅ More efficient than virtio0
    iothread     = true               # ✅ Enable I/O thread for this disk
    discard      = "on"              # ✅ TRIM support
    size         = 1275
    file_format  = "raw"              # ✅ Raw for speed
  }

  scsi_hardware = "virtio-scsi-single" # ✅ Optimal SCSI controller

  boot_order = ["scsi0"]

  network_device {
    bridge = "vmbr1"
    model  = "virtio"                # ✅ Fastest virtual NIC
    firewall = false                 # ✅ Optional: skip Proxmox firewall overhead
  }

  hostpci {
    device  = "hostpci0"
    mapping = "nvidia"               # ✅ GPU passthrough
  }

  initialization {
    datastore_id = "local"
    interface    = "scsi1"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.work_cloud_init_config.id
  }

  depends_on = [ proxmox_virtual_environment_vm.ctrl_rancher_vm ]
}
