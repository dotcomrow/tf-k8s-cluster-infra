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