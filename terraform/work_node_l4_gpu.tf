variable "work_l4_gpu_cpu_cores" {
  type    = number
  default = 20
}

variable "work_l4_gpu_cpu_sockets" {
  type    = number
  default = 1
}

# variable "work_l4_gpu_memory_gb_node0" {
#   type    = number
#   default = 123
# }

variable "work_l4_gpu_memory_gb_node1" {
  type    = number
  default = 123
}

resource "random_integer" "delay_seconds_work_l4_gpu" {
  min = 181
  max = 240

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [proxmox_virtual_environment_vm.srvr_rancher_vm]
}

resource "null_resource" "delay_before_vm_work_l4_gpu" {
  # Only changes if the random value changes (it won't) or srvr-node is replaced
  triggers = {
    delay_val = random_integer.delay_seconds_work_l4_gpu.result
  }

  provisioner "local-exec" {
    command = "echo Sleeping for ${random_integer.delay_seconds_work_l4_gpu.result} seconds... && sleep ${random_integer.delay_seconds_work_l4_gpu.result}"
  }

  # Recreate this delay only when srvr-node VM is replaced
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.srvr_rancher_vm
    ]
  }

  depends_on = [proxmox_virtual_environment_vm.srvr_rancher_vm]
}

# Upload cloud-init configuration to Proxmox as a snippet
resource "proxmox_virtual_environment_file" "work_l4_gpu_cloud_init_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  overwrite = false

  source_raw {
    # path = local_file.ctrl_processed_cloud_init.filename
    data  = templatefile("${path.module}/config/cloud_init_work_l4_gpu.tftpl", {
        hostname   = var.work_l4_gpu_hostname
        k8s_version = var.RKE2_VERSION
        ssh_keys = join("\n      - ", [trimspace(var.admin_ssh_public_key)])
        proxmox_host_ip = var.proxmox_host_ip
        RANCHER_DOMAIN = var.RANCHER_DOMAIN
        GCP_LOGGING_KEY = local.rancher_credentials_json
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.REGION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.work_l4_gpu_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        NVIDIA_DRIVER = var.NVIDIA_DRIVER
        WORK_NODE_MAX_PODS = var.WORK_L4_GPU_NODE_MAX_PODS
      })
    file_name = "cloud_init_work_l4_gpu.yaml"
  }
}

# Define the Proxmox Virtual Machine using BGP Proxmox Provider
resource "proxmox_virtual_environment_vm" "work_l4_gpu_rancher_vm" {
  name      = var.work_l4_gpu_hostname
  node_name = var.node_name
  stop_on_destroy = false
  on_boot = true
  vm_id  = var.work_l4_gpu_vmid

  bios     = "ovmf"  # ✅ Required for q35
  machine  = "q35"   # ✅ Enables PCIe support

  efi_disk {
    datastore_id = var.VM_DISK_STORAGE
    file_format  = "raw"
  }

  cpu {
    cores   = var.work_l4_gpu_cpu_cores
    sockets = var.work_l4_gpu_cpu_sockets
    type    = "host"     # ✅ Best performance
    numa    = true       # ✅ Enable NUMA for >1 socket
    flags   = ["+aes", "+pdpe1gb", "+pcid"]
    affinity = "1,5,9,13,17,21,25,29,33,37,41,45,49,53,57,61,65,69,73,77"
  }

  # numa {
  #   device = "numa0"
  #   cpus   = "0-19"
  #   memory = var.work_l4_gpu_memory_gb_node0 * 1024  # 122 GiB in MiB
  #   hostnodes = "0"
  #   policy    = "bind"
  # }

  numa {
    device = "numa0"
    cpus   = "0-19"
    memory = var.work_l4_gpu_memory_gb_node1 * 1024  # 124 GiB in MiB
    hostnodes = "1"
    policy    = "bind"
  }

  memory {
    # dedicated = var.work_l4_gpu_memory_gb_node0 * 1024 + var.work_l4_gpu_memory_gb_node1 * 1024  # fixed RAM allocation in MiB
    dedicated = var.work_l4_gpu_memory_gb_node1 * 1024  # fixed RAM allocation in MiB
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
    size         = 180
    file_format  = "raw"              # ✅ Raw for speed
    cache     = "unsafe"
  }

  # Dedicated data disk for Longhorn payloads
  disk {
    datastore_id = var.VM_DISK_STORAGE
    interface    = "scsi2"
    iothread     = true
    discard      = "on"
    size         = 800
    file_format  = "raw"
    cache        = "unsafe"
  }

  scsi_hardware = "virtio-scsi-single" # ✅ Optimal SCSI controller

  boot_order = ["scsi0"]

  network_device {
    bridge = "vmbr1"
    model  = "virtio"                # ✅ Fastest virtual NIC
    firewall = false                 # ✅ Optional: skip Proxmox firewall overhead
    queues   = var.work_l4_gpu_cpu_cores * var.work_l4_gpu_cpu_sockets   # match the number of vCPUs you assigned, e.g. 10
    mtu      = 9000                    # if your internal network supports jumbo frames
  }

  hostpci {
    device  = "hostpci0"
    mapping = "nvidia_l4"               # ✅ GPU passthrough
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

    user_data_file_id = proxmox_virtual_environment_file.work_l4_gpu_cloud_init_config.id
  }

  depends_on = [
    null_resource.download_iso,
    null_resource.gate_after_etcd,
    proxmox_virtual_environment_vm.srvr_rancher_vm,
    null_resource.delay_before_vm_work_l4_gpu
  ]
}
