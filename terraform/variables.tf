variable "proxmox_api_username" {
  description = "The Proxmox API username"
  type        = string
}

variable "proxmox_api_password" {
  description = "The Proxmox API password"
  type        = string
}

variable "proxmox_ssh_private_key" {
  description = "The private key for the Proxmox SSH connection"
  type        = string
}

variable "admin_ssh_public_key" {
  description = "The public key for the admin user"
  type        = string
}

variable "k8s_base_version" {
  default = "1.34.3"
  type    = string
}

variable "RKE2_VERSION" {
  default = "v1.34.3+rke2r1"
}

variable "RANCHER_CHART_REPO" {
  default = "stable"
}

variable "LONGHORN_VERSION" {
  type    = string
  default = "v1.10.1"
}

variable "SRVR_IP_ALIAS" {
  type    = string
  default = "10.0.0.109"
}

variable "SRVR_IP_ALIAS_CIDR" {
  type    = string
  default = "24"
}

variable "SRVR_IP_ALIAS_IFACE" {
  type    = string
  default = "eth0"
}

variable "vm_img" {
  default = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  type    = string
}

variable "proxmox_host_ip" {
  default = "10.0.0.1"
  type    = string
}

variable "node_name" {
  default = "pve"
}

variable "work_t4_gpu_hostname" {
  default = "work-node-t4-gpu"
}

variable "work_no_gpu_hostname" {
  default = "work-node-no-gpu"
}

variable "srvr_hostname" {
  default = "srvr-node"
}

variable "etcd_hostname" {
  default = "etcd-node"
}

variable "ctrl_hostname" {
  default = "ctrl-node"
}

variable "RANCHER_HOSTNAME" {
  default = "k8s"
}

variable "RANCHER_DOMAIN" {
  default = "suncoast.systems"
}

variable "GITHUB_AUTH_VAL" {
  default = "github"
}

variable "GITHUB_CLIENT_ID" {
  default = "github"
}

variable "GITHUB_CLIENT_SECRET" {
  default = "github"
}

variable "COCKPIT_HOSTNAME" {
  default = "k8s-cockpit.suncoast.systems"
}

variable "COCKPIT_GITHUB_CLIENT_ID" {
  default = "github"
}

variable "COCKPIT_GITHUB_CLIENT_SECRET" {
  default = "github"
}

variable "COCKPIT_GITHUB_TEAM" {
  default = "k8s_cockpit_access"
}

variable "MONITORED_RESOURCE_TYPE" {
  default = "generic_node"
}

variable "REGION" {
  default = "us-east1"
}

variable "MONITORED_RESOURCE_NAMESPACE" {
  default = "suncoast-systems-k8s"
}

variable "GITHUB_ORG" {
  description = "GitHub organization for the cluster"
  type        = string
  default     = "suncoast-systems-k8s"
}

variable "OAUTH2_PROXY_COOKIE_SECRET" {
  default = "oauth2"
}

variable "GATEWAY_MANAGER_OAUTH2_CLIENT_ID" {
  default = "kong"
}

variable "GATEWAY_MANAGER_OAUTH2_CLIENT_SECRET" {
  default = "kong"
}

variable "VM_DISK_STORAGE" {
  default = "Cluster"
}

variable "UBUNTU_RELEASE_CODE_NAME" {
  default = "noble"
}

variable "NVIDIA_DRIVER" {
  default = "580"
}

variable "ARGOCD_REPO_POST_INSTALL_KEY" {
  default = "argocd"
}

variable "ARGOCD_GITHUB_CLIENT_ID" {
  default = "argocd"
}

variable "ARGOCD_GITHUB_CLIENT_SECRET" {
  default = "argocd"
}

variable "project_name" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The region to use (ex. global or us-east1)"
  type        = string
}

variable "gcp_org_id" {
  description = "The organization id to create the project under"
  type        = string
  nullable = false
}

variable billing_account {
    description = "The billing account to associate with the project"
    type        = string
    nullable = false
}

variable "bucket_name" {
  description = "Name of the bucket"
  type        = string
  default = "proxmox-gcsfuse-bucket"
}

variable "retention_days" {
  description = "Number of days to retain files before auto-deletion"
  type        = number
  default     = 30
}

variable "cluster_name" {
  description = "Name of the on-prem Rancher cluster"
  type        = string
  default     = "local"
}

variable "LINKERD_CLIENT_ID" {
  default = "linkerd"
}

variable "LINKERD_CLIENT_SECRET" {
  default = "linkerd"
}

variable "LINKERD_OAUTH2_PROXY_COOKIE_SECRET" {
  default = "linkerd"
}

variable "LINKERD_GITHUB_AUTH_TEAM" {
  default = "k8s_cluster_admins"
}

variable "OPENOBSERVE_CLIENT_ID" {
  default = "jaeger"
}

variable "OPENOBSERVE_CLIENT_SECRET" {
  default = "jaeger"
}

variable "OPENOBSERVE_GITHUB_TOKEN" {
  description = "GitHub token with read:org for syncing OpenObserve roles"
  type        = string
  default     = ""
  sensitive   = true
}

variable "OPENOBSERVE_GITHUB_ADMIN_TEAM" {
  description = "GitHub team slug whose members should be OpenObserve admins"
  type        = string
  default     = "openobserve_admin_users"
}

variable "OPENOBSERVE_GITHUB_USER_TEAM" {
  description = "GitHub team slug for standard OpenObserve users"
  type        = string
  default     = "openobserve_users"
}

variable "JAEGER_OAUTH2_PROXY_COOKIE_SECRET" {
  default = "jaeger"
}

variable "JAEGER_GITHUB_AUTH_TEAM" {
  default = "k8s_cluster_admins"
}

variable "NFS_DRIVE_STORAGE" {
  default = "300Gi"
}

variable "LINODE_TOKEN" {
  description = "The Linode API token for managing Linode resources"
  type        = string
  default     = "your-linode-api-token"  
}

variable "LINODE_DRIVER_URL" {
  description = "The URL for the Linode driver"
  type        = string
  default     = "https://github.com/dotcomrow/linode-machine-driver-builds/releases/download/v0.1.9/docker-machine-driver-linode"
}

variable "WORK_T4_GPU_NODE_MAX_PODS" {
  description = "Maximum number of pods for the work node T4 gpu"
  type        = number
  default     = 250
}

variable "WORK_NO_GPU_NODE_MAX_PODS" {
  description = "Maximum number of pods for the work node no GPU"
  type        = number
  default     = 250
}

variable "CTRL_NODE_MAX_PODS" {
  description = "Maximum number of pods for the ctrl node"
  type        = number
  default     = 250
}

variable "ETCD_NODE_MAX_PODS" {
  description = "Maximum number of pods for the etcd node"
  type        = number
  default     = 250
}

variable "SRVR_NODE_MAX_PODS" {
  description = "Maximum number of pods for the srvr node"
  type        = number
  default     = 250
}

variable "enable_hugepages" {
  description = "Enable hugepages for VMs"
  type        = bool
  default     = true
}

variable "hugepages_value" {
  description = "Hugepages value in MiB"
  type        = number
  default     = 1024
}

variable "GOOGLE_CREDENTIALS" {
  description = "Path to the GCP service account JSON key file"
  type        = string
  default     = "path/to/your/gcp-service-account.json"
}

variable "VAULT_OIDC_CLIENT_ID" {
  description = "Vault OIDC client ID for authentication"
  type        = string
  default     = "vault-oidc-client-id"
}

variable "VAULT_OIDC_CLIENT_SECRET" {
  description = "Vault OIDC client secret for authentication"
  type        = string
  default     = "vault-oidc-client-secret"
}

variable "VAULT_ADDRESS" {
  description = "Vault address"
  type        = string
  nullable = false
}

variable "apis" {
  description = "The list of apis to enable"  
  type        = list(string)
  default     = [
    "iam.googleapis.com", 
    "cloudresourcemanager.googleapis.com", 
    "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com",
    "cloudbilling.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "containerregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "compute.googleapis.com",
    "eventarc.googleapis.com",                   # ✅ Add this
    "pubsub.googleapis.com",                     # ✅ Recommended (used by Eventarc triggers)
    "secretmanager.googleapis.com",              # ✅ Required for your secret sync
    "logging.googleapis.com"                     # Optional, for better visibility
  ]
}

variable "GHCR_PAT" {
  description = "GitHub Container Registry Personal Access Token"
  type        = string
  default     = "your-ghcr-personal-access-token"
}

variable srvr_vmid {
  description = "The VMID of the srvr-node VM"
  type        = number
  default     = 101
}

variable ctrl_vmid {
  description = "The VMID of the ctrl-node VM"
  type        = number
  default     = 102
}

variable etcd_vmid {
  description = "The VMID of the etcd-node VM"
  type        = number
  default     = 103
}

variable work_t4_gpu_vmid {
  description = "The VMID of the work-node-t4-gpu VM"
  type        = number
  default     = 104
}

variable work_no_gpu_vmid {
  description = "The VMID of the work-node-no-gpu VM"
  type        = number
  default     = 106
}

variable "OPENOBSERVE_IMAGE_TAG" {
  description = "The OpenObserve image tag to use"
  type        = string
  default     = "v0.20.3"
}
