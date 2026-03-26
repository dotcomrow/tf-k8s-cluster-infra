variable "srvr_cpu_cores" {
  type    = number
  default = 13
}

variable "srvr_cpu_sockets" {
  type    = number
  default = 1
}

variable "srvr_memory_gb" {
  type    = number
  default = 102
}

variable "longhorn_guaranteed_instance_manager_cpu" {
  type    = number
  default = 3
}

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
        COCKPIT_HOSTNAME = var.COCKPIT_HOSTNAME
        COCKPIT_GITHUB_CLIENT_ID = var.COCKPIT_GITHUB_CLIENT_ID
        COCKPIT_GITHUB_CLIENT_SECRET = var.COCKPIT_GITHUB_CLIENT_SECRET
        COCKPIT_GITHUB_TEAM = var.COCKPIT_GITHUB_TEAM
        GCP_LOGGING_KEY = local.rancher_credentials_json
        MONITORED_RESOURCE_TYPE = var.MONITORED_RESOURCE_TYPE
        MONITORED_RESOURCE_LOCATION = var.REGION
        MONITORED_RESOURCE_NAMESPACE = var.MONITORED_RESOURCE_NAMESPACE
        MONITORED_RESOURCE_NODE_ID = var.srvr_hostname
        GITHUB_ORG = var.GITHUB_ORG
        OAUTH2_PROXY_COOKIE_SECRET = var.OAUTH2_PROXY_COOKIE_SECRET
        GATEWAY_MANAGER_OAUTH2_CLIENT_ID = var.GATEWAY_MANAGER_OAUTH2_CLIENT_ID
        GATEWAY_MANAGER_OAUTH2_CLIENT_SECRET = var.GATEWAY_MANAGER_OAUTH2_CLIENT_SECRET
        UBUNTU_RELEASE_CODE_NAME = var.UBUNTU_RELEASE_CODE_NAME
        ARGOCD_GITHUB_CLIENT_ID = var.ARGOCD_GITHUB_CLIENT_ID
        ARGOCD_GITHUB_CLIENT_SECRET = var.ARGOCD_GITHUB_CLIENT_SECRET
        ARGOCD_GITHUB_SCM_TOKEN = var.ARGOCD_GITHUB_SCM_TOKEN
        LINKERD_CLIENT_ID = var.LINKERD_CLIENT_ID
        LINKERD_CLIENT_SECRET = var.LINKERD_CLIENT_SECRET
        LINKERD_OAUTH2_PROXY_COOKIE_SECRET = var.LINKERD_OAUTH2_PROXY_COOKIE_SECRET
        LINKERD_GITHUB_AUTH_TEAM = var.LINKERD_GITHUB_AUTH_TEAM
        OPENOBSERVE_CLIENT_ID = var.OPENOBSERVE_CLIENT_ID
        OPENOBSERVE_CLIENT_SECRET = var.OPENOBSERVE_CLIENT_SECRET
        OPENOBSERVE_GITHUB_TOKEN = var.OPENOBSERVE_GITHUB_TOKEN
        OPENOBSERVE_GITHUB_ADMIN_TEAM = var.OPENOBSERVE_GITHUB_ADMIN_TEAM
        OPENOBSERVE_GITHUB_USER_TEAM = var.OPENOBSERVE_GITHUB_USER_TEAM
        JAEGER_OAUTH2_PROXY_COOKIE_SECRET = var.JAEGER_OAUTH2_PROXY_COOKIE_SECRET
        JAEGER_GITHUB_AUTH_TEAM = var.JAEGER_GITHUB_AUTH_TEAM
        NFS_DRIVE_STORAGE = var.NFS_DRIVE_STORAGE
        LINODE_TOKEN = var.LINODE_TOKEN
        LINODE_DRIVER_URL = var.LINODE_DRIVER_URL
        GOOGLE_CREDENTIALS = base64encode(trimspace(var.GOOGLE_CREDENTIALS))
        SRVR_NODE_MAX_PODS = var.SRVR_NODE_MAX_PODS
        GCP_PROJECT_ID = google_project.infra.project_id
        GCP_REGION = var.REGION
        VAULT_KMS_KEY_RING = google_kms_key_ring.vault_infra_ring.name
        VAULT_KEY_ACCOUNT = local.vault_kms_key
        VAULT_OIDC_CLIENT_ID = var.VAULT_OIDC_CLIENT_ID
        VAULT_OIDC_CLIENT_SECRET = var.VAULT_OIDC_CLIENT_SECRET
        TFC_API_TOKEN = var.TFC_API_TOKEN
        TFC_EXTERNAL_APPS_VARSET_ID = var.TFC_EXTERNAL_APPS_VARSET_ID
        TFC_EXTERNAL_APPS_VARSET_NAME = var.TFC_EXTERNAL_APPS_VARSET_NAME
        TFC_ORGANIZATION = var.TFC_ORGANIZATION
        TFC_VAULT_TOKEN_VAR_KEY = var.TFC_VAULT_TOKEN_VAR_KEY
        TFC_API_BASE_URL = var.TFC_API_BASE_URL
        VAULT_VERSION = var.VAULT_VERSION
        KUBECTL_IMAGE_VERSION = var.k8s_base_version
        RANCHER_CHART_REPO = var.RANCHER_CHART_REPO
        CTRL_HOSTNAME = var.ctrl_hostname
        ETCD_HOSTNAME = var.etcd_hostname
        SRVR_HOSTNAME = var.srvr_hostname
        OPENOBSERVE_IMAGE_TAG = var.OPENOBSERVE_IMAGE_TAG
        LONGHORN_VERSION = var.LONGHORN_VERSION
        SRVR_IP_ALIAS = var.SRVR_IP_ALIAS
        SRVR_IP_ALIAS_CIDR = var.SRVR_IP_ALIAS_CIDR
        SRVR_IP_ALIAS_IFACE = var.SRVR_IP_ALIAS_IFACE
        LONGHORN_GUARANTEED_INSTANCE_MANAGER_CPU = var.longhorn_guaranteed_instance_manager_cpu
        NVIDIA_HELM_CHART_VERSION = var.NVIDIA_HELM_CHART_VERSION
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
  vm_id  = var.srvr_vmid

  bios     = "ovmf"  # ✅ Required for q35
  machine  = "q35"   # ✅ Enables PCIe support

  efi_disk {
    datastore_id = var.VM_DISK_STORAGE
    file_format  = "raw"
  }

  cpu {
    cores   = var.srvr_cpu_cores
    sockets = var.srvr_cpu_sockets
    type    = "host"       # ✅ Use host CPU for full feature set
    numa    = true         # ✅ Enable NUMA for multi-socket configs
    flags   = ["+aes", "+pdpe1gb", "+pcid"]
    # Node-3 CPU allocation for srvr VM.
    # Reserved on node3:
    # - Proxmox host: 3,7,43,47
    # - pfSense: 35,75
    # - utility VM: 39,79
    affinity = "11,15,19,23,27,31,51,55,59,63,67,71"
  }

  numa {
    device     = "numa0"
    cpus       = "0-12"
    memory     = var.srvr_memory_gb * 1024  # 100 GiB in MiB
    hostnodes  = "3"
    policy     = "bind"
  }

  memory {
    dedicated = var.srvr_memory_gb * 1024  # fixed RAM allocation in MiB
    hugepages = var.enable_hugepages ? var.hugepages_value : null
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.VM_DISK_STORAGE
    file_id      = "local:iso/${basename(var.vm_img)}"
    interface    = "scsi0"           # ✅ Use SCSI for iothread support
    iothread     = true              # ✅ Improve I/O parallelism
    discard      = "on"
    size         = 120
    file_format  = "raw"             # ✅ Best raw performance
    cache     = "unsafe"
  }

  scsi_hardware = "virtio-scsi-single"  # ✅ Enable for efficient single queue

  boot_order = ["scsi0"]

  network_device {
    bridge   = "vmbr1"
    model    = "virtio"          # ✅ Fastest virtual NIC
    firewall = false             # ✅ Skip Proxmox firewall for performance
    queues   = var.srvr_cpu_cores * var.srvr_cpu_sockets   # match the number of vCPUs you assigned, e.g. 10
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

    user_data_file_id = proxmox_virtual_environment_file.srvr_cloud_init_config.id
  }

  # Make sure all other resources are completed first before building the VM's.  Rancher K8S is dependant on everything happening before it installs.
  depends_on = [ 
    null_resource.download_iso, 
    null_resource.ghcr_to_gcp_image_sync,
    null_resource.tbot_image_sync,
    google_cloud_run_v2_service.vault_sync_svc
  ]
}
