variable "ctrl_cpu_cores" {
  type    = number
  default = 10
}

variable "ctrl_cpu_sockets" {
  type    = number
  default = 1
}

variable "ctrl_memory_gb" {
  type    = number
  default = 61
}

resource "random_integer" "delay_seconds_ctrl" {
  min = 120
  max = 180

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [proxmox_virtual_environment_vm.srvr_rancher_vm]
}

resource "null_resource" "delay_before_vm_ctrl" {
  # Only changes if the random value changes (it won't) or srvr-node is replaced
  triggers = {
    delay_val = random_integer.delay_seconds_ctrl.result
  }

  provisioner "local-exec" {
    command = "echo Sleeping for ${random_integer.delay_seconds_ctrl.result} seconds... && sleep ${random_integer.delay_seconds_ctrl.result}"
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
        MONITORED_RESOURCE_LOCATION = var.REGION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.ctrl_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        CTRL_NODE_MAX_PODS = var.CTRL_NODE_MAX_PODS
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
  vm_id  = var.ctrl_vmid

  bios     = "ovmf"  # ✅ Required for q35
  machine  = "q35"   # ✅ Enables PCIe support

  efi_disk {
    datastore_id = var.VM_DISK_STORAGE
    file_format  = "raw"
  }

  cpu {
    cores   = var.ctrl_cpu_cores
    sockets = var.ctrl_cpu_sockets
    type    = "host"     # ✅ Use host CPU model for full feature set
    numa    = true       # ✅ Enable NUMA for better memory locality
    flags   = ["+aes", "+pdpe1gb", "+pcid", "+spec-ctrl", "+ssbd", "+md-clear"]
    affinity = "2,6,10,14,18,22,26,30,34,38"
  }

  numa {
    device     = "numa0"
    cpus       = "0-9"
    memory     = varl.ctrl_memory_gb * 1024  # 61 GiB in MiB
    hostnodes  = "2"
    policy     = "bind"
  }

  memory {
    dedicated = var.ctrl_memory_gb * 1024  # fixed RAM allocation in MiB
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
    cache     = "writeback"
  }

  scsi_hardware = "virtio-scsi-single"  # ✅ Modern, efficient I/O controller

  boot_order = ["scsi0"]

  network_device {
    bridge   = "vmbr1"
    model    = "virtio"
    firewall = false             # ✅ Reduce overhead, firewalling not needed here
    queues   = var.ctrl_cpu_cores * var.ctrl_cpu_sockets   # match the number of vCPUs you assigned, e.g. 10
    mtu      = 9000                    # if your internal network supports jumbo frames
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

  depends_on = [ 
    proxmox_virtual_environment_vm.srvr_rancher_vm,
    null_resource.delay_before_vm_ctrl
  ]
}