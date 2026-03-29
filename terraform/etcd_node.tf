variable "etcd_cpu_cores" {
  type    = number
  default = 10
}

variable "etcd_cpu_sockets" {
  type    = number
  default = 1
}

variable "etcd_memory_gb" {
  type    = number
  default = 61
}

# Upload cloud-init configuration to Proxmox as a snippet
resource "proxmox_virtual_environment_file" "etcd_cloud_init_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  overwrite = false

  source_raw {
    # path = local_file.ctrl_processed_cloud_init.filename
    data  = templatefile("${path.module}/config/cloud_init_etcd.tftpl", {
        hostname   = var.etcd_hostname
        k8s_version = var.RKE2_VERSION
        ssh_keys = join("\n      - ", [trimspace(var.admin_ssh_public_key)])
        proxmox_host_ip = var.proxmox_host_ip
        RANCHER_DOMAIN = var.RANCHER_DOMAIN
        GCP_LOGGING_KEY = local.rancher_credentials_json
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.REGION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.etcd_hostname
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        ETCD_NODE_MAX_PODS = var.ETCD_NODE_MAX_PODS
      })
    file_name = "cloud_init_etcd.yaml"
  }
}

# Define the Proxmox Virtual Machine using BGP Proxmox Provider
resource "proxmox_virtual_environment_vm" "etcd_rancher_vm" {
  name      = var.etcd_hostname
  node_name = var.node_name
  stop_on_destroy = false
  on_boot = true
  vm_id  = var.etcd_vmid

  bios     = "ovmf"  # ✅ Required for q35
  machine  = "q35"   # ✅ Enables PCIe support
  
  efi_disk {
    datastore_id = var.VM_DISK_STORAGE
    file_format  = "raw"
  }

  cpu {
    cores   = var.etcd_cpu_cores
    sockets = var.etcd_cpu_sockets
    type    = "host"     # ✅ Full CPU instruction set
    numa    = true       # ✅ Enable NUMA for multi-socket configs
    flags   = ["+aes", "+pdpe1gb", "+pcid", "+spec-ctrl", "+ssbd", "+md-clear"]
    # Keep HT sibling pairs on the same VM (node2): (22,62) (26,66) (30,70) (34,74) (38,78)
    affinity = "22,26,30,34,38,62,66,70,74,78"
  }

  numa {
    device     = "numa0"
    cpus       = "0-9"
    memory     = var.etcd_memory_gb * 1024  # 61 GiB in MiB
    hostnodes  = "2"
    policy     = "bind"
  }

  memory {
    dedicated = var.etcd_memory_gb * 1024  # fixed RAM allocation in MiB
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
    size         = 100
    file_format  = "raw"             # ✅ Faster I/O
    cache     = "writeback"
  }

  scsi_hardware = "virtio-scsi-single"  # ✅ Best for single-queue low-latency disk ops

  boot_order = ["scsi0"]

  network_device {
    bridge   = "vmbr1"
    model    = "virtio"
    firewall = false             # ✅ Reduce overhead, not needed for etcd VM
    queues   = var.etcd_cpu_cores * var.etcd_cpu_sockets   # match the number of vCPUs you assigned, e.g. 10
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

    user_data_file_id = proxmox_virtual_environment_file.etcd_cloud_init_config.id
  }

  depends_on = [ 
    null_resource.download_iso,
    proxmox_virtual_environment_vm.srvr_rancher_vm
  ]
}
