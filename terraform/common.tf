resource "null_resource" "download_iso" {
  triggers = {
    iso_url = var.vm_img
  }

  provisioner "local-exec" {
    command = "echo \"${var.proxmox_ssh_private_key}\" > tmp_key && chmod 600 tmp_key && ssh -o StrictHostKeyChecking=no -i tmp_key root@127.0.0.1 'ISO_NAME=$(basename ${var.vm_img}) && ISO_PATH=\"/var/lib/vz/template/iso/$ISO_NAME\" && mkdir -p '/var/lib/vz/template/iso' && if [ ! -f \"$ISO_PATH\" ]; then echo \"$ISO_NAME not found at $ISO_PATH. Downloading...\" && wget -O \"$ISO_PATH\" \"${var.vm_img}\"; else echo 'ISO already exists. Skipping download.'; fi'"

    environment = {
      PROXMOX_HOST = "127.0.0.1"
      SSH_PRIVATE_KEY = var.proxmox_ssh_private_key
    }
  }

  depends_on = [
    google_service_account.rancher_sa,
    google_project.infra
  ]
}

resource "null_resource" "gate_after_etcd" {
  count = var.serialize_vm_rollout ? 1 : 0

  depends_on = [
    proxmox_virtual_environment_vm.etcd_rancher_vm
  ]
}
