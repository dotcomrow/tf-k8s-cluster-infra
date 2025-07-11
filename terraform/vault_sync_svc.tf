locals {
  image_tag = formatdate("YYYYMMDDHHmmss", timestamp())
}

resource "google_project_service" "project_service" {
  count = length(var.apis)

  disable_dependent_services = true
  project = google_project.infra.project_id
  service = var.apis[count.index]
}

data "google_compute_default_service_account" "default" {
  project = google_project.infra.project_id

  depends_on = [ google_project_service.project_service ]
}

resource "google_project_iam_member" "registry_permissions" {
  project = google_project.infra.project_id
  role   = "roles/composer.environmentAndStorageObjectViewer"
  member  = "serviceAccount:service-${google_project.infra.number}@serverless-robot-prod.iam.gserviceaccount.com"

  depends_on = [ data.google_compute_default_service_account.default ]
}

resource "google_project_iam_member" "artifact_permissions" {
  project = google_project.infra.project_id
  role   = "roles/artifactregistry.reader"
  member  = "serviceAccount:service-${google_project.infra.number}@serverless-robot-prod.iam.gserviceaccount.com"

  depends_on = [ data.google_compute_default_service_account.default ]
}

resource "google_project_iam_member" "secret_manager_grant" {
  project = google_project.infra.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_v2_service" "vault_sync_svc" {
  name     = "vault-sync-run-container"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  project  = "${google_project.infra.project_id}"
  deletion_protection = false

  template {
    service_account = google_service_account.eventarc_service_account.email
    containers {
      image = "${var.region}-docker.pkg.dev/${google_project.infra.project_id}/vault-sync-run-container/vault-sync-run-container:${local.image_tag}"

      env {
        name  = "GCP_PROJECT_ID"
        value = google_project.infra.project_id
      }

      env {
        name  = "VAULT_ADDR"
        value = var.VAULT_ADDRESS
      }

      env {
        name  = "VAULT_ROLE_ID"
        value = var.VAULT_ROLE_ID
      }

      env {
        name  = "VAULT_SECRET_ID"
        value = var.VAULT_SECRET_ID
      }
    }
  }

  depends_on = [
    google_project_iam_member.registry_permissions,
    google_project_iam_member.secret_manager_grant,
    null_resource.ghcr_to_gcp_image_sync,
    google_service_account.eventarc_service_account,
    google_project_iam_member.cloud_run_secret_access,
    google_pubsub_topic.secret_manager_events,
    google_project_iam_member.eventarc_receive_auditlog,
    null_resource.kms_iam_binding
  ]

}

resource "google_cloud_run_service_iam_policy" "noauth-user-profile" {
  location = google_cloud_run_v2_service.vault_sync_svc.location
  project  = google_cloud_run_v2_service.vault_sync_svc.project
  service  = google_cloud_run_v2_service.vault_sync_svc.name

  policy_data = data.google_iam_policy.noauth.policy_data

  depends_on = [ 
      google_cloud_run_v2_service.vault_sync_svc,
      google_eventarc_trigger.vault_secret_events
   ]
}

resource "google_artifact_registry_repository" "vault_sync_repo" {
  location        = var.region
  repository_id   = "vault-sync-run-container"
  format          = "DOCKER"
  project         = google_project.infra.project_id
  description     = "Hosted repo for vault-sync image"

  depends_on = [ google_project_service.project_service ]
}

resource "null_resource" "ghcr_to_gcp_image_sync" {
  provisioner "local-exec" {
    environment = {
      GHCR_USER   = var.GITHUB_ORG
      PROJECT_NAME = "vault-sync-run-container"
      IMAGE_NAME  = "vault-sync-run-container"
      REGION      = var.region
      PROJECT_ID  = google_project.infra.project_id
      IMAGE_TAG   = local.image_tag
    }

    command = <<-EOT
      #!/bin/bash

      # Setup directories for isolated gcloud and docker configs
      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      export DOCKER_CONFIG="$(pwd)/.docker"
      mkdir -p "$CLOUDSDK_CONFIG" "$DOCKER_CONFIG"

      # Download gcloud SDK and configure PATH
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"

      # Authenticate with GCP
      printf "%s" "$GOOGLE_CREDENTIALS" > key.json
      gcloud auth activate-service-account --key-file=key.json
      gcloud config set project "$PROJECT_ID"

      # ✅ Login to Artifact Registry directly
      echo "$(gcloud auth print-access-token)" | docker login -u oauth2accesstoken --password-stdin https://$REGION-docker.pkg.dev
      gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

      # Delete all images in Artifact Registry repo (digests + tags)
      REPO_PATH="$REGION-docker.pkg.dev/$PROJECT_ID/$PROJECT_NAME/$IMAGE_NAME"
      EXISTING_IMAGES=$(gcloud artifacts docker images list "$REPO_PATH" --format="get(version)" || true)
      for image in $EXISTING_IMAGES; do
        gcloud artifacts docker images delete "$REPO_PATH@$image" --quiet --delete-tags || true
      done

      # Pull from GHCR
      docker pull "ghcr.io/$GHCR_USER/$IMAGE_NAME:latest"

      # Tag and push to GCP Artifact Registry
      docker tag "ghcr.io/$GHCR_USER/$IMAGE_NAME:latest" \
        "$REGION-docker.pkg.dev/$PROJECT_ID/$PROJECT_NAME/$IMAGE_NAME:${local.image_tag}"

      docker push "$REGION-docker.pkg.dev/$PROJECT_ID/$PROJECT_NAME/$IMAGE_NAME:${local.image_tag}"

      echo "✅ GHCR image successfully synced to GCP Artifact Registry."
    EOT
  }

  triggers = {
    always_run = "${timestamp()}"
  }

  depends_on = [ google_artifact_registry_repository.vault_sync_repo ]
}
