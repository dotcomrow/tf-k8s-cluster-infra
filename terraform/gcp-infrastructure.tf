# Create random suffix
resource "random_id" "suffix_gcp" {
  byte_length = 2
}

# Create GCP project
resource "google_project" "infra" {
  name            = var.project_name
  project_id      = "${var.project_name}-${random_id.suffix_gcp.hex}"
  org_id          = var.gcp_org_id
  billing_account = var.billing_account
}

# Service account for WIF impersonation
resource "google_service_account" "rancher_sa" {
  provider    = google.infra
  account_id  = "rancher-${var.cluster_name}-agent"
  project     = google_project.infra.project_id
  display_name = "WIF Service Account for Rancher Cluster ${var.cluster_name}"

  depends_on = [ google_project.infra ]
}

# Workload Identity Pool
resource "google_iam_workload_identity_pool" "rancher_pool" {
  provider                    = google-beta.infra
  project                     = google_project.infra.project_id
  workload_identity_pool_id   = "rancher-${var.cluster_name}-pool"
  display_name                = "Rancher Cluster ${var.cluster_name} Pool"

  depends_on = [ google_project.infra ]
}

# Workload Identity Pool Provider
resource "google_iam_workload_identity_pool_provider" "rancher_provider" {
  provider                        = google-beta.infra
  project                         = google_project.infra.project_id
  workload_identity_pool_id       = google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "rancher-${var.cluster_name}-provider"
  display_name                    = "OIDC Provider for ${var.cluster_name}"

  oidc {
    issuer_uri = var.k8s_oidc_issuer
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  depends_on = [ google_project.infra ]
}

# IAM Binding for Workload Identity Impersonation
resource "google_service_account_iam_member" "rancher_wif_binding" {
  provider           = google.infra
  service_account_id = google_service_account.rancher_sa.name
  role               = "roles/iam.workloadIdentityUser"

  member = "principalSet://iam.googleapis.com/projects/${google_project.infra.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id}/subject/system:serviceaccount:${var.namespace}:${var.service_account}"

  depends_on = [
    google_iam_workload_identity_pool.rancher_pool,
    google_iam_workload_identity_pool_provider.rancher_provider
  ]
}

# Optional: Logging permission for the service account
resource "google_project_iam_member" "rancher_logging_permission" {
  provider = google.infra
  project  = google_project.infra.project_id
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${google_service_account.rancher_sa.email}"

  depends_on = [ google_project.infra ]
}

# Optional: GCS bucket to test access
resource "google_storage_bucket" "free_tier_safe_bucket" {
  provider     = google.infra
  name         = "${var.bucket_name}-${random_id.suffix_gcp.hex}"
  location     = var.region
  project      = google_project.infra.project_id
  force_destroy = true
  storage_class = "STANDARD"

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.retention_days
    }
  }

  labels = {
    purpose = "k8s-gp-store"
  }

  depends_on = [ google_project.infra ]
}

resource "google_storage_bucket_iam_member" "wif_bucket_access" {
  provider = google.infra
  bucket   = google_storage_bucket.free_tier_safe_bucket.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.rancher_sa.email}"
}

# Optional: External credentials block (e.g., for cloud-init or Secret)
locals {
  rancher_wif_credentials_json = jsonencode({
    type                             = "external_account"
    audience                         = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.rancher_provider.name}"
    subject_token_type               = "urn:ietf:params:oauth:token-type:jwt"
    token_url                        = "https://sts.googleapis.com/v1/token"
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.rancher_sa.email}:generateAccessToken"
    credential_source = {
      file = "/var/run/secrets/tokens/oidc"
    }
  })
}
