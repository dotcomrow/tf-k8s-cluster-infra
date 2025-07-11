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

locals {
  ghcr_digest_tag = replace(data.external.ghcr_digest.result.digest, ":", "-")
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
      image = "${var.region}-docker.pkg.dev/${google_project.infra.project_id}/vault-sync-run-container/vault-sync-run-container:${local.ghcr_digest_tag}"

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

resource "google_cloud_run_service_iam_member" "noauth_user" {
  location = google_cloud_run_v2_service.vault_sync_svc.location
  project  = google_cloud_run_v2_service.vault_sync_svc.project
  service  = google_cloud_run_v2_service.vault_sync_svc.name

  role   = "roles/run.invoker"
  member = "allUsers"
}

resource "google_artifact_registry_repository" "vault_sync_repo" {
  location      = var.region
  repository_id = "vault-sync-run-container"
  format        = "DOCKER"
  project       = google_project.infra.project_id
  description   = "Hosted repo for vault-sync image"
  depends_on = [google_project_service.project_service]
}

data "external" "ghcr_digest" {
  program = [
    "bash", "-c",
    <<-EOT
      set -e
      IMAGE="ghcr.io/${var.GITHUB_ORG}/vault-sync-run-container:latest"

      # Make 100% sure it's removed
      docker image rm -f "$IMAGE" > /dev/null 2>&1 || true
      docker system prune -af > /dev/null 2>&1 || true

      # Force pull latest version
      docker pull "$IMAGE" > /dev/null

      # Capture digest
      DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" | cut -d@ -f2)

      # Fallback or error if digest is missing
      if [ -z "$DIGEST" ]; then
        echo "Failed to get digest" >&2
        exit 1
      fi

      echo "{\"digest\": \"$DIGEST\"}"
    EOT
  ]
}

data "external" "gcp_digest" {
  program = [
    "bash", "-c",
    <<-EOT
      set -e
      docker image rm -f IMAGE 2>/dev/null || true
      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      export DOCKER_CONFIG="$(pwd)/.docker"
      mkdir -p "$CLOUDSDK_CONFIG" "$DOCKER_CONFIG"
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz 1>&2
      tar -xf google-cloud-cli-linux-x86_64.tar.gz 1>&2
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"
      printf '%s' '${var.GOOGLE_CREDENTIALS}' > key.json
      gcloud auth activate-service-account --key-file=key.json 1>&2
      gcloud config set project 'tf-k8s-cluster-infra-9734' 1>&2
      echo "$(gcloud auth print-access-token)" | docker login -u oauth2accesstoken --password-stdin https://us-east1-docker.pkg.dev 1>&2
      gcloud auth configure-docker us-east1-docker.pkg.dev --quiet 1>&2
      if ! docker pull "us-east1-docker.pkg.dev/tf-k8s-cluster-infra-9734/vault-sync-run-container/vault-sync-run-container:latest" > /dev/null 2>&1; then
        echo "{\"digest\": \"none\"}"
        exit 0
      fi
      echo "{\"digest\": \"$(docker inspect --format='{{index .RepoDigests 0}}' us-east1-docker.pkg.dev/tf-k8s-cluster-infra-9734/vault-sync-run-container/vault-sync-run-container:latest | cut -d@ -f2)\"}"
    EOT
  ]
}

resource "null_resource" "ghcr_to_gcp_image_sync" {
  provisioner "local-exec" {
    environment = {
      GHCR_USER    = var.GITHUB_ORG
      PROJECT_NAME = "vault-sync-run-container"
      IMAGE_NAME   = "vault-sync-run-container"
      REGION       = var.region
      PROJECT_ID   = google_project.infra.project_id
    }

    command = <<-EOT
      #!/bin/bash
      set -e
      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      export DOCKER_CONFIG="$(pwd)/.docker"
      mkdir -p "$CLOUDSDK_CONFIG" "$DOCKER_CONFIG"
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"
      printf "%s" "$GOOGLE_CREDENTIALS" > key.json
      gcloud auth activate-service-account --key-file=key.json
      gcloud config set project "$PROJECT_ID"
      echo "$(gcloud auth print-access-token)" | docker login -u oauth2accesstoken --password-stdin https://$REGION-docker.pkg.dev
      gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
      REPO_PATH="$REGION-docker.pkg.dev/$PROJECT_ID/$PROJECT_NAME/$IMAGE_NAME"
      LATEST_DIGEST=$(gcloud artifacts docker images list "$REPO_PATH" --filter="tags:latest" --format="get(digest)" || true)
      if [[ -n "$LATEST_DIGEST" ]]; then
        gcloud artifacts docker images delete "$REPO_PATH@$LATEST_DIGEST" --quiet --delete-tags || true
      fi
      docker pull "ghcr.io/$GHCR_USER/$IMAGE_NAME:latest"
      docker tag "ghcr.io/$GHCR_USER/$IMAGE_NAME:latest" "$REPO_PATH:$(docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/$GHCR_USER/$IMAGE_NAME:latest | cut -d@ -f2 | sed 's/:/-/')"
      docker push "$REPO_PATH:$(docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/$GHCR_USER/$IMAGE_NAME:latest | cut -d@ -f2 | sed 's/:/-/')"
      docker tag "ghcr.io/$GHCR_USER/$IMAGE_NAME:latest" "$REPO_PATH:latest"
      docker push "$REPO_PATH:latest"
      echo "✅ GHCR image successfully synced to GCP Artifact Registry."
    EOT
  }

  triggers = {
    digest_comparison_hash = "${data.external.ghcr_digest.result.digest}-${data.external.gcp_digest.result.digest}"
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_artifact_registry_repository.vault_sync_repo]
}
