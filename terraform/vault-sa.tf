resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "logging.googleapis.com",
    "compute.googleapis.com" # more as needed
  ])
  project = google_project.infra.project_id
  service = each.key
  disable_on_destroy = false
}

resource "google_kms_key_ring" "infra_ring" {
  name     = "shared-infra-ring"
  location = var.region
  project  = google_project.infra.project_id

  depends_on = [google_project_service.enabled_apis]
}

resource "google_kms_crypto_key" "vault_key" {
  name            = "vault-unseal"
  key_ring        = google_kms_key_ring.infra_ring.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "100000s"
}

resource "google_service_account" "vault" {
  account_id   = "vault-unseal"
  display_name = "Vault Unseal Service Account"
  project      = google_project.infra.project_id
}

resource "google_service_account_key" "vault_key" {
  service_account_id = google_service_account.vault.name
  private_key_type   = "TYPE_GOOGLE_CREDENTIALS_FILE"
}

locals {
  vault_kms_key = google_service_account_key.vault_key.private_key
}

resource "google_kms_crypto_key_iam_member" "vault_kms_access" {
  crypto_key_id = google_kms_crypto_key.vault_key.id
  role          = "projects/${google_project.infra.project_id}/roles/${google_project_iam_custom_role.vault_kms.role_id}"
  member        = "serviceAccount:${google_service_account.vault.email}"
}

# give GCP’s KMS service-agent permission to view key usage
resource "google_organization_iam_member" "kms_org_service_agent" {
  org_id = var.gcp_org_id               # your 936642400324 org ID
  role   = "roles/cloudkms.orgServiceAgent"
  member = "serviceAccount:service-org-${var.gcp_org_id}@gcp-sa-cloudkms.iam.gserviceaccount.com"
}

resource "google_project_iam_custom_role" "vault_kms" {
  role_id     = "vaultKmsAccess"
  title       = "Vault KMS Access"
  description = "Minimal permissions to allow Vault auto-unseal via GCP KMS"
  project     = google_project.infra.project_id

  permissions = [
    "cloudkms.cryptoKeyVersions.useToEncrypt",
    "cloudkms.cryptoKeyVersions.useToDecrypt",
    "cloudkms.cryptoKeys.get",
  ]
}
