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

variable "RKE2_VERSION" {
  default = "v1.31.3+rke2r1"  
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

variable "work_hostname" {
  default = "work-node"
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

variable "MONITORED_RESOURCE_TYPE" {
  default = "gce_instance"
}

variable "MONITORED_RESOURCE_LOCATION" {
  default = "global"
}

variable "MONITORED_RESOURCE_NAMESPACE" {
  default = "k8s"
}

variable "GITHUB_ORG" {
  default = "suncoast-systems"
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
  default = "570"
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

variable "JAEGER_CLIENT_ID" {
  default = "jaeger"
}

variable "JAEGER_CLIENT_SECRET" {
  default = "jaeger"
}

variable "JAEGER_OAUTH2_PROXY_COOKIE_SECRET" {
  default = "jaeger"
}

variable "JAEGER_GITHUB_AUTH_TEAM" {
  default = "k8s_cluster_admins"
}

variable "NFS_DRIVE_STORAGE" {
  default = "200Gi"
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

variable "WORK_NODE_MAX_PODS" {
  description = "Maximum number of pods for the work node"
  type        = number
  default     = 250
}

variable "enable_hugepages" {
  description = "Enable hugepages for VMs"
  type        = bool
  default     = true
}