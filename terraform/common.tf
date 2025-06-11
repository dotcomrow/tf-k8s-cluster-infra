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
    google_service_account_key.logging_key,
    google_storage_bucket.free_tier_safe_bucket,
    google_storage_bucket_iam_member.storage_bucket_access,
    google_project.infra
  ]
}

resource "null_resource" "remove_known_hosts" {
  provisioner "local-exec" {
    command = "echo \"${var.proxmox_ssh_private_key}\" > tmp_key && chmod 600 tmp_key && ssh -o StrictHostKeyChecking=no -i tmp_key root@127.0.0.1 'sudo rm -rf ~/.ssh/known_hosts'"

    environment = {
      PROXMOX_HOST = "127.0.0.1"
      SSH_PRIVATE_KEY = var.proxmox_ssh_private_key
    }
  }

  depends_on = [proxmox_virtual_environment_vm.work_rancher_vm]
}

resource "null_resource" "add_hosts_entries" {
  provisioner "local-exec" {
    command = "echo \"${var.proxmox_ssh_private_key}\" > tmp_key && chmod 600 tmp_key && ssh -o StrictHostKeyChecking=no -i tmp_key root@127.0.0.1 'for entry in \"work-node.internal.lan\" \"srvr-node.internal.lan\" \"ctrl-node.internal.lan\" \"etcd-node.internal.lan\"; do sudo sed -i \"/$entry/d\" /etc/hosts; done && echo -e \"$(dig +short work-node.internal.lan @10.0.0.10) work-node.internal.lan\n$(dig +short srvr-node.internal.lan @10.0.0.10) srvr-node.internal.lan\n$(dig +short ctrl-node.internal.lan @10.0.0.10) ctrl-node.internal.lan\n$(dig +short etcd-node.internal.lan @10.0.0.10) etcd-node.internal.lan\" | sudo tee -a /etc/hosts > /dev/null'"

    environment = {
      PROXMOX_HOST = "127.0.0.1"
      SSH_PRIVATE_KEY = var.proxmox_ssh_private_key
    }
  }

  depends_on = [ null_resource.remove_known_hosts ]
}

resource "null_resource" "add_known_hosts" {
  provisioner "local-exec" {
    command = "echo \"${var.proxmox_ssh_private_key}\" > tmp_key && chmod 600 tmp_key && ssh -o StrictHostKeyChecking=no -i tmp_key root@127.0.0.1 'ssh-keyscan -H srvr-node.internal.lan >> ~/.ssh/known_hosts; ssh-keyscan -H ctrl-node.internal.lan >> ~/.ssh/known_hosts; ssh-keyscan -H etcd-node.internal.lan >> ~/.ssh/known_hosts; ssh-keyscan -H work-node.internal.lan >> ~/.ssh/known_hosts;'"
    
    environment = {
      PROXMOX_HOST = "127.0.0.1"
      SSH_PRIVATE_KEY = var.proxmox_ssh_private_key
    }
  }

  depends_on = [null_resource.add_hosts_entries]
}