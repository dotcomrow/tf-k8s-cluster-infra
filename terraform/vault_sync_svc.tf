locals {
  existing_tag_file_content = try(trimspace(file("${path.module}/.ghcr_tag.txt")), "")
}

resource "null_resource" "get_ghcr_tag" {
  triggers = {
    tag_value = local.existing_tag_file_content
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      curl -s -H "Authorization: Bearer ${var.GHCR_PAT}" \
        https://api.github.com/users/${var.GITHUB_ORG}/packages/container/vault-sync-run-container/versions \
        | jq -r '.[].metadata.container.tags[]' \
        | grep '^ts-' | sort -r | head -n1 > ${path.module}/.ghcr_tag.txt
    EOT
  }
}

data "local_file" "ghcr_tag_file" {
  depends_on = [null_resource.get_ghcr_tag]
  filename   = "${path.module}/.ghcr_tag.txt"
}

locals {
  image_tag = trimspace(data.local_file.ghcr_tag_file.content)
}

resource "google_project_service" "project_service" {
  count = length(var.apis)

  disable_dependent_services = true
  project = google_project.infra.project_id
  service = var.apis[count.index]
}

data "google_compute_default_service_account" "default" {
  project = google_project.infra.project_id
  depends_on = [google_project_service.project_service]
}

resource "google_project_iam_member" "registry_permissions" {
  project = google_project.infra.project_id
  role    = "roles/composer.environmentAndStorageObjectViewer"
  member  = "serviceAccount:service-${google_project.infra.number}@serverless-robot-prod.iam.gserviceaccount.com"
  depends_on = [data.google_compute_default_service_account.default]
}

resource "google_project_iam_member" "artifact_permissions" {
  project = google_project.infra.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:service-${google_project.infra.number}@serverless-robot-prod.iam.gserviceaccount.com"
  depends_on = [data.google_compute_default_service_account.default]
}

resource "google_project_iam_member" "secret_manager_grant" {
  project = google_project.infra.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

resource "google_cloud_run_v2_service" "vault_sync_svc" {
  name     = "vault-sync-run-container"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  project  = google_project.infra.project_id
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

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_iam_member.registry_permissions,
    google_project_iam_member.secret_manager_grant,
    null_resource.ghcr_to_gcp_image_sync,
    google_service_account.eventarc_service_account,
    google_project_iam_member.cloud_run_secret_access,
    google_pubsub_topic.secret_manager_events,
    google_project_iam_member.eventarc_receive_auditlog,
    null_resource.kms_iam_binding,
    google_project_iam_member.cloud_run_secret_list
  ]
}

resource "google_project_iam_member" "cloud_run_secret_list" {
  project = google_project.infra.project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.eventarc_service_account.email}"
}

resource "google_cloud_run_service_iam_member" "eventarc_invoker" {
  location = google_cloud_run_v2_service.vault_sync_svc.location
  project  = google_cloud_run_v2_service.vault_sync_svc.project
  service  = google_cloud_run_v2_service.vault_sync_svc.name

  role   = "roles/run.invoker"
  member = "serviceAccount:${google_service_account.eventarc_service_account.email}"
}

resource "google_artifact_registry_repository" "vault_sync_repo" {
  location      = var.region
  repository_id = "vault-sync-run-container"
  format        = "DOCKER"
  project       = google_project.infra.project_id
  description   = "Hosted repo for vault-sync image"
  depends_on = [google_project_service.project_service]
}

output "selected_image_tag" {
  value = local.image_tag
}

resource "null_resource" "image_sync_complete" {
  triggers = {
    tag = local.image_tag
  }
}

resource "null_resource" "ghcr_to_gcp_image_sync" {
  provisioner "local-exec" {
    environment = {
      GHCR_USER    = var.GITHUB_ORG
      GHCR_PAT     = var.GHCR_PAT
      PROJECT_ID   = google_project.infra.project_id
      REGION       = var.region
      IMAGE_NAME   = "vault-sync-run-container"
      TAG          = local.image_tag
    }

    command = <<-EOT
      #!/bin/bash
      set -e

      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      export DOCKER_CONFIG="$(pwd)/.docker"
      mkdir -p "$CLOUDSDK_CONFIG" "$DOCKER_CONFIG"

      # Install gcloud CLI
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"

      # Authenticate to GCP
      printf "%s" "$GOOGLE_CREDENTIALS" > key.json
      gcloud auth activate-service-account --key-file=key.json
      gcloud config set project "$PROJECT_ID"
      echo "$(gcloud auth print-access-token)" | docker login -u oauth2accesstoken --password-stdin "https://$REGION-docker.pkg.dev"
      gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

      # Authenticate to GHCR
      echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

      # Validate vars
      if [ -z "$TAG" ] || [ -z "$IMAGE_NAME" ] || [ -z "$GHCR_USER" ]; then
        echo "❌ One or more required variables are empty: TAG=$TAG, IMAGE_NAME=$IMAGE_NAME, GHCR_USER=$GHCR_USER"
        exit 1
      fi

      GHCR_IMAGE="ghcr.io/$GHCR_USER/$IMAGE_NAME:$TAG"
      REPO_PATH="$REGION-docker.pkg.dev/$PROJECT_ID/$IMAGE_NAME/$IMAGE_NAME"

      echo "📦 Pulling from GHCR: $GHCR_IMAGE"
      docker pull "$GHCR_IMAGE"

      echo "🧹 Cleaning up existing images in Artifact Registry..."
      for digest in $(gcloud artifacts docker images list "$REPO_PATH" --format="get(digest)" || true); do
        gcloud artifacts docker images delete "$REPO_PATH@$digest" --quiet --delete-tags || true
      done

      echo "🚀 Tagging and pushing image to GCP Artifact Registry: $REPO_PATH:$TAG"
      docker tag "$GHCR_IMAGE" "$REPO_PATH:$TAG"
      docker push "$REPO_PATH:$TAG"

      echo "✅ GHCR image successfully pushed to GCP with tag $TAG"
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_artifact_registry_repository.vault_sync_repo,
    null_resource.image_sync_complete,
    null_resource.get_ghcr_tag
  ]
}

