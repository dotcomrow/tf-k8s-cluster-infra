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
        MONITORED_RESOURCE_LOCATION = var.REGION
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

  bios     = "ovmf"  # ✅ Required for q35
  machine  = "q35"   # ✅ Enables PCIe support

  efi_disk {
    datastore_id = var.VM_DISK_STORAGE
    file_format  = "raw"
  }

  cpu {
    cores   = 20
    sockets = 3
    type    = "host"     # ✅ Best performance
    numa    = true       # ✅ Enable NUMA for >1 socket
    flags   = "+aes,+pdpe1gb,+pcid"
  }

  numa {
    device = "numa0"
    cpus   = "0-19"
    memory = 123904  # 122 GiB in MiB
    hostnodes = "0"
    policy    = "bind"
  }

  numa {
    device = "numa1"
    cpus   = "20-39"
    memory = 123904  # 124 GiB in MiB
    hostnodes = "1"
    policy    = "bind"
  }

  numa {
    device = "numa2"
    cpus   = "40-59"
    memory = 123904  # 124 GiB in MiB
    hostnodes = "2"
    policy    = "bind"
  }

  memory {
    dedicated = 371712       # fixed RAM allocation in MiB
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
    size         = 1175
    file_format  = "raw"              # ✅ Raw for speed
    cache     = "unsafe"
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
    rombar    = true            # ✅ Required for full NVIDIA driver compatibility
    pcie      = true            # ✅ Enables PCIe mode (needed for modern GPUs)
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

resource "null_resource" "enable_viommu_work_node" {
  depends_on = [proxmox_virtual_environment_vm.work_rancher_vm]

  provisioner "local-exec" {
    command = <<EOT
      qm set ${proxmox_virtual_environment_vm.work_rancher_vm.vm_id} \
        -machine type=q35,viommu=on
    EOT
  }
}