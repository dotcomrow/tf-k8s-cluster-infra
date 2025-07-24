variable "work_cpu_cores" {
  type    = number
  default = 20
}

variable "work_cpu_sockets" {
  type    = number
  default = 2
}

resource "random_integer" "delay_seconds_work" {
  min = 181
  max = 240

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [proxmox_virtual_environment_vm.srvr_rancher_vm]
}

resource "null_resource" "delay_before_vm_work" {
  provisioner "local-exec" {
    command = "echo Sleeping for ${random_integer.delay_seconds_work.result} seconds... && sleep ${random_integer.delay_seconds_work.result}"
  }

  triggers = {
    always_run = timestamp()
    delay_val  = random_integer.delay_seconds_work.result
  }
}

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
    cores   = var.work_cpu_cores
    sockets = var.work_cpu_sockets
    type    = "host"     # ✅ Best performance
    numa    = true       # ✅ Enable NUMA for >1 socket
    flags   = ["+aes", "+pdpe1gb", "+pcid"]
  }

  numa {
    device = "numa0"
    cpus   = "0-19"
    memory = 124928  # 122 GiB in MiB
    hostnodes = "0"
    policy    = "bind"
  }

  numa {
    device = "numa1"
    cpus   = "20-39"
    memory = 124928  # 124 GiB in MiB
    hostnodes = "1"
    policy    = "bind"
  }

  memory {
    dedicated = 249856       # fixed RAM allocation in MiB
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
    queues   = var.work_cpu_cores * var.work_cpu_sockets   # match the number of vCPUs you assigned, e.g. 10
    mtu      = 9000                    # if your internal network supports jumbo frames
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

  depends_on = [ 
    proxmox_virtual_environment_vm.srvr_rancher_vm,
    null_resource.delay_before_vm_work
  ]
}