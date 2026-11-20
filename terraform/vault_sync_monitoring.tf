resource "google_monitoring_notification_channel" "vault_sync_email" {
  project      = google_project.infra.project_id
  display_name = "Vault sync infrastructure alerts"
  type         = "email"

  labels = {
    email_address = var.vault_sync_alert_email
  }

  force_delete = false

  depends_on = [google_project_service.project_service]
}

resource "google_monitoring_alert_policy" "vault_sync_subscription_missing" {
  project      = google_project.infra.project_id
  display_name = "CRITICAL: Vault sync subscription missing"
  combiner     = "OR"
  severity     = "CRITICAL"

  dynamic "conditions" {
    for_each = local.secret_event_methods

    content {
      display_name = "${conditions.key} subscription metric absent"

      condition_absent {
        filter = join(" AND ", [
          "resource.type=\"pubsub_subscription\"",
          "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\"",
          "resource.label.\"subscription_id\"=\"vault-${replace(conditions.key, "_", "-")}-push\"",
        ])
        duration = "900s"

        aggregations {
          alignment_period   = "300s"
          per_series_aligner = "ALIGN_MAX"
        }
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Vault sync Pub/Sub subscription is missing"
    content   = <<-EOT
      A required Vault sync Pub/Sub subscription stopped reporting metrics.
      This can mean the subscription was deleted or expired and Secret Manager
      audit events are no longer reaching the Vault sync Cloud Run service.

      Verify all `vault-*-push` subscriptions, restore them through Terraform,
      and use the authenticated `/sync-all` endpoint to backfill missed values.
    EOT
  }

  notification_channels = [google_monitoring_notification_channel.vault_sync_email.name]

  alert_strategy {
    auto_close           = "604800s"
    notification_prompts = ["OPENED", "CLOSED"]
  }

  user_labels = {
    component = "vault-sync"
    severity  = "critical"
  }

  depends_on = [
    google_project_service.project_service,
    google_pubsub_subscription.vault_secret_event_push,
  ]
}

resource "google_monitoring_alert_policy" "vault_sync_push_failures" {
  project      = google_project.infra.project_id
  display_name = "CRITICAL: Vault sync push delivery failing"
  combiner     = "OR"
  severity     = "CRITICAL"

  dynamic "conditions" {
    for_each = local.secret_event_methods

    content {
      display_name = "${conditions.key} push failures"

      condition_threshold {
        filter = join(" AND ", [
          "resource.type=\"pubsub_subscription\"",
          "metric.type=\"pubsub.googleapis.com/subscription/push_request_count\"",
          "resource.label.\"subscription_id\"=\"vault-${replace(conditions.key, "_", "-")}-push\"",
          "metric.label.\"response_class\"!=\"ack\"",
        ])
        comparison      = "COMPARISON_GT"
        threshold_value = 0
        duration        = "0s"

        aggregations {
          alignment_period   = "300s"
          per_series_aligner = "ALIGN_SUM"
        }
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Vault sync Pub/Sub push delivery is failing"
    content   = <<-EOT
      Pub/Sub is failing to deliver Secret Manager audit events to the Vault
      sync Cloud Run service. Check Cloud Run request/application logs, service
      account invocation permissions, and Vault endpoint connectivity.
    EOT
  }

  notification_channels = [google_monitoring_notification_channel.vault_sync_email.name]

  alert_strategy {
    auto_close           = "86400s"
    notification_prompts = ["OPENED", "CLOSED"]
  }

  user_labels = {
    component = "vault-sync"
    severity  = "critical"
  }

  depends_on = [
    google_project_service.project_service,
    google_pubsub_subscription.vault_secret_event_push,
  ]
}
