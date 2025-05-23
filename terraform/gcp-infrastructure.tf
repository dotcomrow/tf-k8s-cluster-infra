resource "random_id" "suffix_gcp" {
  byte_length = 2
}

resource "google_project" "infra" {
  name       = var.project_name
  project_id = "${var.project_name}-${random_id.suffix_gcp.hex}"
  org_id     = var.gcp_org_id
  billing_account = "${var.billing_account}"
}

resource "google_project_iam_member" "rancher_logging_permission" {
  project = google_project.infra.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.rancher_sa.email}"
}

resource "google_iam_workload_identity_pool" "rancher_pool" {
  provider = google-beta
  project = google_project.infra.project_id
  workload_identity_pool_id = "rancher-${var.cluster_name}-pool"
  display_name              = "Rancher Cluster ${var.cluster_name} Pool"
}

resource "google_iam_workload_identity_pool_provider" "rancher_provider" {
  provider = google-beta
  project  = google_project.infra.project_id

  workload_identity_pool_id          = google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "rancher-${var.cluster_name}-provider"
  display_name                       = "OIDC Provider for ${var.cluster_name}"

  oidc {
    issuer_uri = var.k8s_oidc_issuer
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
    "attribute.k8s_ns" = "assertion.sub.extract('system:serviceaccount:(.*?):(.*?)')[1]"
    "attribute.k8s_sa" = "assertion.sub.extract('system:serviceaccount:(.*?):(.*?)')[2]"
  }
}

resource "google_service_account" "rancher_sa" {
  account_id   = "rancher-${var.cluster_name}-agent"
  project = google_project.infra.project_id
  display_name = "WIF Service Account for Rancher Cluster ${var.cluster_name}"
}

resource "google_service_account_iam_member" "rancher_wif_binding" {
  service_account_id = google_service_account.rancher_sa.name
  
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.rancher_pool.name}/attribute.k8s_ns/${var.namespace}/attribute.k8s_sa/${var.service_account}"
}

resource "google_storage_bucket" "free_tier_safe_bucket" {
  name     = "${var.bucket_name}-${random_id.suffix_gcp.hex}"
  location = var.region
  project  = google_project.infra.project_id
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
    purpose = "free-tier-data-bucket"
  }
}

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