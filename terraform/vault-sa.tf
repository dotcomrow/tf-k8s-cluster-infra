resource "google_kms_key_ring" "vault_infra_ring" {
  name     = "vault-infra-ring-2"
  location = var.region
  project  = google_project.infra.project_id
}

resource "google_kms_crypto_key" "vault_crypto_key" {
  name            = "vault-unseal"
  key_ring        = google_kms_key_ring.vault_infra_ring.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "100000s"
}

resource "google_service_account" "vault_crypto_unseal_acct" {
  account_id   = "vault-unseal"
  display_name = "Vault Unseal Service Account"
  project      = google_project.infra.project_id
}

resource "google_service_account_key" "vault_crypto_key" {
  service_account_id = google_service_account.vault_crypto_unseal_acct.email
  private_key_type   = "TYPE_GOOGLE_CREDENTIALS_FILE"

  depends_on = [
    google_service_account.vault_crypto_unseal_acct,
    google_kms_crypto_key.vault_crypto_key,
    null_resource.kms_iam_binding
  ]
}

locals {
  vault_kms_key = google_service_account_key.vault_crypto_key.private_key
}

resource "google_project_iam_custom_role" "vault_kms_crypto_role" {
  role_id     = "kmsVaultSyncRole"
  title       = "Vault KMS Crypto Access"
  description = "Minimal permissions to allow Vault auto-unseal via GCP KMS"
  project     = google_project.infra.project_id

  permissions = [
    "cloudkms.cryptoKeyVersions.useToEncrypt",
    "cloudkms.cryptoKeyVersions.useToDecrypt",
    "cloudkms.cryptoKeys.get",
  ]
}

resource "google_organization_iam_member" "kms_crypto_org_service_agent" {
  org_id = var.gcp_org_id
  role   = "roles/cloudkms.orgServiceAgent"
  member = "serviceAccount:service-org-${var.gcp_org_id}@gcp-sa-cloudkms.iam.gserviceaccount.com"
}

resource "null_resource" "wait_for_custom_role" {
  depends_on = [google_project_iam_custom_role.vault_kms_crypto_role]

  provisioner "local-exec" {
    command = "echo 'Waiting for custom IAM role propagation...'; sleep 90"
  }
}

resource "null_resource" "kms_iam_binding" {
  depends_on = [
    google_kms_crypto_key.vault_crypto_key,
    google_service_account.vault_crypto_unseal_acct,
    null_resource.wait_for_custom_role,
    google_kms_crypto_key.vault_crypto_key
  ]

  provisioner "local-exec" {
    command = <<EOT
      echo "Applying IAM binding for Vault KMS..."

      curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      ./google-cloud-sdk/install.sh
      printf '%s' "$GOOGLE_CREDENTIALS" > key.json

      ./google-cloud-sdk/bin/gcloud auth activate-service-account --key-file=key.json
      ./google-cloud-sdk/bin/gcloud config set project ${google_project.infra.project_id}
      ./google-cloud-sdk/bin/gcloud config set compute/region ${var.region}

      ./google-cloud-sdk/bin/gcloud kms keys add-iam-policy-binding vault-unseal \
        --location=${var.region} \
        --keyring=vault-infra-ring \
        --member="serviceAccount:${google_service_account.vault_crypto_unseal_acct.email}" \
        --role="projects/${google_project.infra.project_id}/roles/${google_project_iam_custom_role.vault_kms_crypto_role.role_id}" \
        --project=${google_project.infra.project_id}
    EOT
  }
}
