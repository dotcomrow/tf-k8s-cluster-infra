variable "proxmox_api_endpoint" {
  description = "The Proxmox API endpoint"
  type        = string
}

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

variable "GCP_LOGGING_KEY" {
  default = "gcp"
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

variable "KONG_MANAGER_OAUTH2_CLIENT_ID" {
  default = "kong"
}

variable "KONG_MANAGER_OAUTH2_CLIENT_SECRET" {
  default = "kong"
}

variable "KONG_MANAGER_GITHUB_AUTH_TEAM" {
  default = "k8s_cluster_admins"
}

variable "VM_DISK_STORAGE" {
  default = "Cluster"
}

variable "UBUNTU_RELEASE_CODE_NAME" {
  default = "noble"
}

variable "PROXMOX_HOSTNAME" {
  default = "proxmox"
}

variable "NVIDIA_DRIVER" {
  default = "570"
}

variable "FLEET_REPO_POST_INSTALL_KEY" {
  default = "fleet"
}

variable "ARGOCD_REPO_POST_INSTALL_KEY" {
  default = "argocd"
}

variable "PROXMOX_SSH_PORT" {
  default = "22"
}

variable "ARGOCD_GITHUB_CLIENT_ID" {
  default = "argocd"
}

variable "ARGOCD_GITHUB_CLIENT_SECRET" {
  default = "argocd"
}
