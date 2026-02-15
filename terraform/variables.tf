###############################################################################
# Input Variables
#
# Notes:
# - Variables are grouped by functional area for easier discovery.
# - Uppercase variable names are intentionally preserved: many are passed
#   directly into cloud-init templates.
# - Secrets/tokens/keys are marked `sensitive = true` to reduce accidental leaks
#   in CLI output and logs.
###############################################################################

###############################################################################
# Proxmox Access
###############################################################################

variable "proxmox_api_username" {
  description = "Proxmox API username (for the bpg/proxmox provider)."
  type        = string
}

variable "proxmox_api_password" {
  description = "Proxmox API password (for the bpg/proxmox provider)."
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_private_key" {
  description = "Private key contents used for SSH to Proxmox (provider ssh block and ISO download)."
  type        = string
  sensitive   = true
}

variable "admin_ssh_public_key" {
  description = "SSH public key installed for the admin user on created VMs."
  type        = string
}

###############################################################################
# Proxmox Host / VM Image
###############################################################################

variable "proxmox_host_ip" {
  description = "IP address of the Proxmox host (used by VMs to mount the NFS share)."
  type        = string
  default     = "10.0.0.1"
}

variable "node_name" {
  description = "Proxmox node name where VMs are created (e.g. 'pve')."
  type        = string
  default     = "pve"
}

variable "VM_DISK_STORAGE" {
  description = "Proxmox datastore_id used for VM disks/EFI disks (e.g. 'local-lvm' or 'Cluster')."
  type        = string
  default     = "Cluster"
}

variable "vm_img" {
  description = "Ubuntu cloud image URL to download into Proxmox and use for VMs."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "UBUNTU_RELEASE_CODE_NAME" {
  description = "Ubuntu release code name used by cloud-init templates (e.g. 'noble')."
  type        = string
  default     = "noble"
}

###############################################################################
# VM Naming / Identity
###############################################################################

variable "srvr_hostname" {
  description = "Hostname for the srvr node VM (Rancher/cluster services)."
  type        = string
  default     = "srvr-node"
}

variable "etcd_hostname" {
  description = "Hostname for the etcd node VM."
  type        = string
  default     = "etcd-node"
}

variable "ctrl_hostname" {
  description = "Hostname for the control-plane node VM."
  type        = string
  default     = "ctrl-node"
}

variable "work_t4_gpu_hostname" {
  description = "Hostname for the GPU worker node VM."
  type        = string
  default     = "work-node-t4-gpu"
}

variable "work_no_gpu_hostname" {
  description = "Hostname for the non-GPU worker node VM."
  type        = string
  default     = "work-node-no-gpu"
}

###############################################################################
# Networking
###############################################################################

variable "SRVR_IP_ALIAS" {
  description = "Secondary IP address to add to the srvr node (used by cloud-init)."
  type        = string
  default     = "10.0.0.109"
}

variable "SRVR_IP_ALIAS_CIDR" {
  description = "CIDR prefix length for SRVR_IP_ALIAS (string to match template usage; e.g. '24')."
  type        = string
  default     = "24"
}

variable "SRVR_IP_ALIAS_IFACE" {
  description = "Interface name on the srvr node to attach SRVR_IP_ALIAS to (e.g. 'eth0')."
  type        = string
  default     = "eth0"
}

###############################################################################
# Kubernetes / Component Versions
###############################################################################

variable "k8s_base_version" {
  description = "Kubernetes version used for auxiliary tooling/images (e.g. kubectl)."
  type        = string
  default     = "1.34.3"
}

variable "RKE2_VERSION" {
  description = "RKE2 release version to install on nodes (e.g. 'v1.34.3+rke2r1')."
  type        = string
  default     = "v1.34.3+rke2r1"
}

variable "RANCHER_CHART_REPO" {
  description = "Rancher Helm chart repository channel (e.g. 'stable', 'latest')."
  type        = string
  default     = "stable"
}

variable "LONGHORN_VERSION" {
  description = "Longhorn version to deploy."
  type        = string
  default     = "v1.10.1"
}

variable "VAULT_VERSION" {
  description = "Vault version to deploy."
  type        = string
  default     = "1.21.2"
}

variable "OPENOBSERVE_IMAGE_TAG" {
  description = "OpenObserve image tag to deploy."
  type        = string
  default     = "v0.20.3"
}

variable "NVIDIA_DRIVER" {
  description = "NVIDIA driver major version to install on worker nodes (Ubuntu 'nvidia-<ver>-server' packages)."
  type        = string
  default     = "580"
}

variable "NVIDIA_HELM_CHART_VERSION" {
  description = "Version of the NVIDIA Helm chart to deploy."
  type        = string
  default     = "v25.10.1"
}

###############################################################################
# Rancher / Cluster Identity
###############################################################################

variable "cluster_name" {
  description = "Name of the on-prem Rancher cluster (also used for some GCP resource naming)."
  type        = string
  default     = "local"
}

variable "RANCHER_HOSTNAME" {
  description = "Hostname prefix for Rancher UI (combined with RANCHER_DOMAIN)."
  type        = string
  default     = "k8s"
}

variable "RANCHER_DOMAIN" {
  description = "Base DNS domain for cluster services (e.g. 'example.com')."
  type        = string
  default     = "suncoast.systems"
}

###############################################################################
# GitHub / Registry
###############################################################################

variable "GITHUB_ORG" {
  description = "GitHub org or username used for GHCR access and allowed-group checks."
  type        = string
  default     = "suncoast-systems-k8s"
}

variable "GHCR_PAT" {
  description = "GitHub Container Registry Personal Access Token used by automation (e.g. to fetch image tags)."
  type        = string
  default     = "your-ghcr-personal-access-token"
  sensitive   = true
}

###############################################################################
# Rancher GitHub Auth
###############################################################################

variable "GITHUB_AUTH_VAL" {
  description = "GitHub team slug used for Rancher RBAC mapping in bootstrap templates."
  type        = string
  default     = "github"
}

variable "GITHUB_CLIENT_ID" {
  description = "GitHub OAuth app client ID used by Rancher."
  type        = string
  default     = "github"
}

variable "GITHUB_CLIENT_SECRET" {
  description = "GitHub OAuth app client secret used by Rancher."
  type        = string
  default     = "github"
  sensitive   = true
}

###############################################################################
# Cockpit (oauth2-proxy) GitHub OAuth
###############################################################################

variable "COCKPIT_HOSTNAME" {
  description = "FQDN for Cockpit (used for oauth2-proxy redirect URL and allowed domains)."
  type        = string
  default     = "k8s-cockpit.suncoast.systems"
}

variable "COCKPIT_GITHUB_CLIENT_ID" {
  description = "GitHub OAuth app client ID used by Cockpit's oauth2-proxy."
  type        = string
  default     = "github"
}

variable "COCKPIT_GITHUB_CLIENT_SECRET" {
  description = "GitHub OAuth app client secret used by Cockpit's oauth2-proxy."
  type        = string
  default     = "github"
  sensitive   = true
}

variable "COCKPIT_GITHUB_TEAM" {
  description = "GitHub team slug allowed to access Cockpit via oauth2-proxy."
  type        = string
  default     = "k8s_cockpit_access"
}

###############################################################################
# Gateway Manager (oauth2-proxy)
###############################################################################

variable "OAUTH2_PROXY_COOKIE_SECRET" {
  description = "Cookie secret used by oauth2-proxy instances."
  type        = string
  default     = "oauth2"
  sensitive   = true
}

variable "GATEWAY_MANAGER_OAUTH2_CLIENT_ID" {
  description = "OIDC/OAuth client ID used by the Gateway Manager oauth2-proxy."
  type        = string
  default     = "kong"
}

variable "GATEWAY_MANAGER_OAUTH2_CLIENT_SECRET" {
  description = "OIDC/OAuth client secret used by the Gateway Manager oauth2-proxy."
  type        = string
  default     = "kong"
  sensitive   = true
}

###############################################################################
# Argo CD GitHub OAuth
###############################################################################

variable "ARGOCD_REPO_POST_INSTALL_KEY" {
  description = "Post-install key/material used by Argo CD repository bootstrapping."
  type        = string
  default     = "argocd"
  sensitive   = true
}

variable "ARGOCD_GITHUB_CLIENT_ID" {
  description = "GitHub OAuth app client ID used by Argo CD."
  type        = string
  default     = "argocd"
}

variable "ARGOCD_GITHUB_CLIENT_SECRET" {
  description = "GitHub OAuth app client secret used by Argo CD."
  type        = string
  default     = "argocd"
  sensitive   = true
}

variable "ARGOCD_GITHUB_SCM_TOKEN" {
  description = "GitHub token used by Argo CD for SCM access."
  type        = string
  default     = "argocd"
  sensitive   = true
}

###############################################################################
# Linkerd (oauth2-proxy)
###############################################################################

variable "LINKERD_CLIENT_ID" {
  description = "OIDC/OAuth client ID used by Linkerd auth components."
  type        = string
  default     = "linkerd"
}

variable "LINKERD_CLIENT_SECRET" {
  description = "OIDC/OAuth client secret used by Linkerd auth components."
  type        = string
  default     = "linkerd"
  sensitive   = true
}

variable "LINKERD_OAUTH2_PROXY_COOKIE_SECRET" {
  description = "Cookie secret used by Linkerd's oauth2-proxy."
  type        = string
  default     = "linkerd"
  sensitive   = true
}

variable "LINKERD_GITHUB_AUTH_TEAM" {
  description = "GitHub team slug allowed to access Linkerd via oauth2-proxy."
  type        = string
  default     = "k8s_cluster_admins"
}

###############################################################################
# OpenObserve GitHub OAuth
###############################################################################

variable "OPENOBSERVE_CLIENT_ID" {
  description = "GitHub OAuth app client ID used by OpenObserve."
  type        = string
  default     = "jaeger"
}

variable "OPENOBSERVE_CLIENT_SECRET" {
  description = "GitHub OAuth app client secret used by OpenObserve."
  type        = string
  default     = "jaeger"
  sensitive   = true
}

variable "OPENOBSERVE_GITHUB_TOKEN" {
  description = "GitHub token with read:org for syncing OpenObserve roles."
  type        = string
  default     = ""
  sensitive   = true
}

variable "OPENOBSERVE_GITHUB_ADMIN_TEAM" {
  description = "GitHub team slug whose members should be OpenObserve admins."
  type        = string
  default     = "openobserve_admin_users"
}

variable "OPENOBSERVE_GITHUB_USER_TEAM" {
  description = "GitHub team slug for standard OpenObserve users."
  type        = string
  default     = "openobserve_users"
}

###############################################################################
# Jaeger (oauth2-proxy)
###############################################################################

variable "JAEGER_OAUTH2_PROXY_COOKIE_SECRET" {
  description = "Cookie secret used by Jaeger's oauth2-proxy."
  type        = string
  default     = "jaeger"
  sensitive   = true
}

variable "JAEGER_GITHUB_AUTH_TEAM" {
  description = "GitHub team slug allowed to access Jaeger via oauth2-proxy."
  type        = string
  default     = "k8s_cluster_admins"
}

###############################################################################
# Monitoring / Resource Labels
###############################################################################

variable "MONITORED_RESOURCE_TYPE" {
  description = "Monitored resource type used by node logging/metrics agents (e.g. 'generic_node')."
  type        = string
  default     = "generic_node"
}

variable "REGION" {
  description = "Location/region label used by node agents and bootstrap templates (distinct from var.region used by GCP resources)."
  type        = string
  default     = "us-east1"
}

variable "MONITORED_RESOURCE_NAMESPACE" {
  description = "Namespace label used by node logging/metrics agents."
  type        = string
  default     = "suncoast-systems-k8s"
}

###############################################################################
# Storage / VM Runtime Settings
###############################################################################

variable "NFS_DRIVE_STORAGE" {
  description = "Requested storage size for NFS-backed storage (Kubernetes quantity string; e.g. '300Gi')."
  type        = string
  default     = "300Gi"
}

variable "enable_hugepages" {
  description = "Enable hugepages for VMs."
  type        = bool
  default     = true
}

variable "hugepages_value" {
  description = "Hugepages value in MiB (used when enable_hugepages is true)."
  type        = number
  default     = 1024
}

variable "serialize_vm_rollout" {
  description = "If true, enforce srvr -> etcd -> all other VMs ordering (others remain parallel)."
  type        = bool
  default     = false
}

###############################################################################
# Kubelet Settings
###############################################################################

variable "WORK_T4_GPU_NODE_MAX_PODS" {
  description = "Maximum number of pods for the GPU worker node."
  type        = number
  default     = 250
}

variable "WORK_NO_GPU_NODE_MAX_PODS" {
  description = "Maximum number of pods for the non-GPU worker node."
  type        = number
  default     = 250
}

variable "CTRL_NODE_MAX_PODS" {
  description = "Maximum number of pods for the control-plane node."
  type        = number
  default     = 250
}

variable "ETCD_NODE_MAX_PODS" {
  description = "Maximum number of pods for the etcd node."
  type        = number
  default     = 250
}

variable "SRVR_NODE_MAX_PODS" {
  description = "Maximum number of pods for the srvr node."
  type        = number
  default     = 250
}

###############################################################################
# External Providers / Integrations
###############################################################################

variable "LINODE_TOKEN" {
  description = "Linode API token for managing Linode resources."
  type        = string
  default     = "your-linode-api-token"
  sensitive   = true
}

variable "LINODE_DRIVER_URL" {
  description = "URL for the Linode Docker Machine driver binary used by Rancher."
  type        = string
  default     = "https://github.com/dotcomrow/linode-machine-driver-builds/releases/download/v0.1.9/docker-machine-driver-linode"
}

###############################################################################
# Vault
###############################################################################

variable "VAULT_ADDRESS" {
  description = "Vault address (e.g. 'https://vault.example.com:8200')."
  type        = string
  nullable    = false
}

variable "VAULT_OIDC_CLIENT_ID" {
  description = "OIDC client ID used by Vault for authentication."
  type        = string
  default     = "vault-oidc-client-id"
}

variable "VAULT_OIDC_CLIENT_SECRET" {
  description = "OIDC client secret used by Vault for authentication."
  type        = string
  default     = "vault-oidc-client-secret"
  sensitive   = true
}

###############################################################################
# Terraform Cloud / HCP Terraform
###############################################################################

variable "TFC_API_TOKEN" {
  description = "Terraform Cloud API token used by node bootstrap to manage variable-set values."
  type        = string
  default     = ""
  sensitive   = true
}

variable "TFC_EXTERNAL_APPS_VARSET_ID" {
  description = "Terraform Cloud variable set ID that should receive the Vault root token (optional when TFC_EXTERNAL_APPS_VARSET_NAME is set)."
  type        = string
  default     = ""
}

variable "TFC_EXTERNAL_APPS_VARSET_NAME" {
  description = "Terraform Cloud variable set name used to resolve the target variable set when ID is not provided."
  type        = string
  default     = "Cloudflare Platform Variables"
}

variable "TFC_ORGANIZATION" {
  description = "Terraform Cloud organization name used when resolving variable sets by name."
  type        = string
  default     = "dotcomrow"
}

variable "TFC_VAULT_TOKEN_VAR_KEY" {
  description = "Terraform variable key in the target variable set to store the Vault root token."
  type        = string
  default     = "VAULT_TOKEN"
}

variable "TFC_API_BASE_URL" {
  description = "Terraform Cloud API base URL."
  type        = string
  default     = "https://app.terraform.io/api/v2"
}

###############################################################################
# Google Cloud (Bootstrap / Runtime)
###############################################################################

variable "project_name" {
  description = "GCP project name/prefix used when creating the infra project."
  type        = string
  nullable    = false
}

variable "region" {
  description = "GCP region used by Terraform-managed resources (e.g. 'us-east1')."
  type        = string
  nullable    = false
}

variable "gcp_org_id" {
  description = "GCP organization ID to create the project under."
  type        = string
  nullable    = false
}

variable "billing_account" {
  description = "GCP billing account to associate with the project."
  type        = string
  nullable    = false
}

variable "apis" {
  description = "List of Google APIs to enable in the created project."
  type        = list(string)
  default = [
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
    "eventarc.googleapis.com",      # Eventarc triggers
    "pubsub.googleapis.com",        # Used by Eventarc triggers
    "secretmanager.googleapis.com", # Required for secret sync
    "logging.googleapis.com",       # Optional, for better visibility
  ]
}

variable "bucket_name" {
  description = "Name of the GCS bucket (if/when bucket resources are enabled)."
  type        = string
  default     = "proxmox-gcsfuse-bucket"
}

variable "retention_days" {
  description = "Number of days to retain files before auto-deletion (for buckets/lifecycle rules)."
  type        = number
  default     = 30
}

variable "GOOGLE_CREDENTIALS" {
  description = "GCP service account JSON key contents (passed into node bootstrap and written to disk)."
  type        = string
  default     = "path/to/your/gcp-service-account.json"
  sensitive   = true
}

###############################################################################
# Proxmox VM IDs
###############################################################################

variable "srvr_vmid" {
  description = "Proxmox VMID for the srvr node VM."
  type        = number
  default     = 101
}

variable "ctrl_vmid" {
  description = "Proxmox VMID for the control-plane node VM."
  type        = number
  default     = 102
}

variable "etcd_vmid" {
  description = "Proxmox VMID for the etcd node VM."
  type        = number
  default     = 103
}

variable "work_t4_gpu_vmid" {
  description = "Proxmox VMID for the GPU worker node VM."
  type        = number
  default     = 104
}

variable "work_no_gpu_vmid" {
  description = "Proxmox VMID for the non-GPU worker node VM."
  type        = number
  default     = 106
}
