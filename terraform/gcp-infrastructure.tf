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

resource "google_storage_bucket_iam_member" "storage_bucket_access" {
  provider = google.infra
  bucket   = google_storage_bucket.free_tier_safe_bucket.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.rancher_sa.email}"
  depends_on = [ google_storage_bucket.free_tier_safe_bucket ]
}

resource "google_service_account_key" "logging_key" {
  service_account_id = google_service_account.rancher_sa.name
  private_key_type   = "TYPE_GOOGLE_CREDENTIALS_FILE"
  depends_on = [ google_storage_bucket_iam_member.storage_bucket_access ]
}

# Optional: External credentials block (e.g., for cloud-init or Secret)
locals {
  rancher_credentials_json = google_service_account_key.logging_key.private_key
}
