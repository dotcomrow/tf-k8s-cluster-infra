locals {
  secret_event_methods = {
    create_secret = "google.cloud.secretmanager.v1.SecretManagerService.CreateSecret"
    update_secret = "google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret"
    delete_secret = "google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret"
    add_version   = "google.cloud.secretmanager.v1.SecretManagerService.AddSecretVersion"
  }
}

resource "google_project_iam_audit_config" "secret_manager_audit_logs" {
  project = google_project.infra.project_id
  service = "secretmanager.googleapis.com"

  audit_log_config {
    log_type          = "ADMIN_READ"
    exempted_members = []
  }

  audit_log_config {
    log_type          = "DATA_READ"
    exempted_members = []
  }

  audit_log_config {
    log_type          = "DATA_WRITE"
    exempted_members = []
  }
}

resource "google_eventarc_trigger" "vault_secret_events" {
  for_each = local.secret_event_methods

  name     = "vault-${replace(each.key, "_", "-")}-trigger"
  location = var.region
  project  = google_project.infra.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.audit.log.v1.written"
  }

  matching_criteria {
    attribute = "serviceName"
    value     = "secretmanager.googleapis.com"
  }

  matching_criteria {
    attribute = "methodName"
    value     = each.value
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.vault_sync_svc.name
      region  = var.region
    }
  }

  service_account = google_service_account.eventarc_service_account.email

  depends_on = [
    google_project_service.project_service,
    google_cloud_run_v2_service.vault_sync_svc
  ]
}

resource "google_cloud_run_service_iam_member" "allow_eventarc" {
  project  = google_project.infra.project_id
  location = var.region
  service  = google_cloud_run_v2_service.vault_sync_svc.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc_service_account.email}"
}

resource "google_service_account" "eventarc_service_account" {
  account_id   = "eventarc-vault-sync"
  display_name = "Eventarc Trigger for Vault Sync"
  project      = google_project.infra.project_id
}

resource "google_project_iam_member" "eventarc_invoker" {
  project = google_project.infra.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_cloud_run_v2_service.vault_sync_svc.template[0].service_account}"
}

resource "google_project_iam_member" "pubsub_subscriber" {
  project = google_project.infra.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_cloud_run_v2_service.vault_sync_svc.template[0].service_account}"
}

resource "google_project_iam_member" "eventarc_receive_auditlog" {
  project = google_project.infra.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.eventarc_service_account.email}"
}

resource "google_project_iam_member" "cloud_run_secret_access" {
  project = google_project.infra.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eventarc_service_account.email}"
}
