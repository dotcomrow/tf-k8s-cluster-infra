resource "null_resource" "download_iso" {
  triggers = {
    iso_url   = var.vm_img
    preflight = timestamp()
  }

  provisioner "local-exec" {
    command = "echo \"${var.proxmox_ssh_private_key}\" > tmp_key && chmod 600 tmp_key && ssh -o StrictHostKeyChecking=no -i tmp_key root@127.0.0.1 'set -e; ISO_NAME=$(basename ${var.vm_img}); ISO_PATH=\"/var/lib/vz/template/iso/$ISO_NAME\"; mkdir -p \"/var/lib/vz/template/iso\"; if [ -f \"$ISO_PATH\" ]; then if ! qemu-img info \"$ISO_PATH\" >/dev/null 2>&1; then echo \"ISO invalid; removing $ISO_PATH\"; rm -f \"$ISO_PATH\"; fi; fi; if [ ! -f \"$ISO_PATH\" ]; then tmp=\"$ISO_PATH.tmp.$$\"; echo \"Downloading $ISO_NAME to $tmp\"; wget -O \"$tmp\" \"${var.vm_img}\"; qemu-img info \"$tmp\" >/dev/null 2>&1; mv \"$tmp\" \"$ISO_PATH\"; else echo \"ISO already valid: $ISO_PATH\"; fi'"

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
