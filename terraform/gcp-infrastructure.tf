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

data "google_client_openid_userinfo" "me" {}

resource "google_project_iam_member" "grant_wif_creator_to_sa" {
  project = google_project.infra.project_id
  role    = "roles/iam.workloadIdentityPoolAdmin"
  member  = "serviceAccount:${data.google_client_openid_userinfo.me.email}"

  depends_on = [google_project.infra]
}

# Service account for WIF impersonation
resource "google_service_account" "rancher_sa" {
  provider    = google.infra
  account_id  = "rancher-${var.cluster_name}-agent"
  project     = google_project.infra.project_id
  display_name = "WIF Service Account for Rancher Cluster ${var.cluster_name}"

  depends_on = [ google_project.infra ]
}

resource "null_resource" "wait_for_iam_propagation" {
  provisioner "local-exec" {
    command = "echo '⏳ Waiting for IAM propagation...'; sleep 30"
    interpreter = ["bash", "-c"]
  }

  triggers = {
    project_id = google_project.infra.project_id
  }

  depends_on = [
    google_project_iam_member.grant_wif_creator_to_sa
  ]
}

# Workload Identity Pool
resource "google_iam_workload_identity_pool" "rancher_pool" {
  provider = google-beta.infra
  project  = google_project.infra.project_id
  workload_identity_pool_id = "rancher-${var.cluster_name}-pool-${random_id.suffix_gcp.hex}"
  display_name              = "Rancher Cluster ${var.cluster_name} Pool"

  depends_on = [
    null_resource.wait_for_iam_propagation
  ]
}

# Workload Identity Pool Provider
resource "google_iam_workload_identity_pool_provider" "rancher_provider" {
  provider                        = google-beta.infra
  project                         = google_project.infra.project_id
  workload_identity_pool_id       = google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "rancher-${var.cluster_name}-provider-${random_id.suffix_gcp.hex}"
  display_name                    = "OIDC Provider for ${var.cluster_name}"

  oidc {
    issuer_uri = var.k8s_oidc_issuer
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  depends_on = [ google_project.infra ]
}

locals {
  principal_set_member = "principalSet://iam.googleapis.com/projects/${google_project.infra.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id}/subject/system:serviceaccount:${var.namespace}:${var.service_account}"
}

resource "null_resource" "wait_for_oidc_issuer" {
  provisioner "local-exec" {
    command = <<EOT
      for i in $(seq 1 60); do
        echo "🔄 Waiting for OIDC issuer to respond..."
        curl --silent --fail --show-error --location --max-time 5 "${var.k8s_oidc_issuer}/.well-known/openid-configuration" && exit 0
        sleep 5
      done
      echo "❌ Timeout waiting for OIDC issuer at ${var.k8s_oidc_issuer}"
      exit 1
    EOT
    interpreter = ["bash", "-c"]
  }
}


resource "google_service_account_iam_member" "rancher_wif_binding" {
  provider           = google.infra
  service_account_id = google_service_account.rancher_sa.name
  role               = "roles/iam.workloadIdentityUser"

  member     = local.principal_set_member

  depends_on = [
    null_resource.wait_for_oidc_issuer
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

# Debug output for the WIF credentials

output "project_id" {
  value       = google_project.infra.project_id
  description = "GCP Project ID"
}

output "project_number" {
  value       = google_project.infra.number
  description = "GCP Project Number"
}

output "workload_identity_pool_id" {
  value       = google_iam_workload_identity_pool.rancher_pool.workload_identity_pool_id
  description = "Workload Identity Pool ID (short ID, not full name)"
}

output "workload_identity_pool_full_name" {
  value       = google_iam_workload_identity_pool.rancher_pool.name
  description = "Full resource name of Workload Identity Pool"
}

output "workload_identity_pool_provider_id" {
  value       = google_iam_workload_identity_pool_provider.rancher_provider.workload_identity_pool_provider_id
  description = "Workload Identity Pool Provider ID"
}

output "workload_identity_pool_provider_full_name" {
  value       = google_iam_workload_identity_pool_provider.rancher_provider.name
  description = "Full resource name of Workload Identity Pool Provider"
}

output "principal_set_member" {
  value       = local.principal_set_member
  description = "The exact principalSet string being used in the IAM binding"
}

output "wif_service_account_email" {
  value       = google_service_account.rancher_sa.email
  description = "Email of the WIF service account being bound"
}

output "oidc_issuer_uri" {
  value       = var.k8s_oidc_issuer
  description = "OIDC issuer URI configured in the WIF provider"
}
