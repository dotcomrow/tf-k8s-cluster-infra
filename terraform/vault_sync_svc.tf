# 1. External data source fetches latest tag
data "external" "ghcr_tag" {
  program = ["bash", "-c", <<-EOT
    set -e
    TAG=$(curl -s \
      -H "Authorization: Bearer ${var.GHCR_PAT}" \
      https://api.github.com/users/${var.GITHUB_ORG}/packages/container/vault-sync-run-container/versions \
      | jq -r '.[].metadata.container.tags[]' \
      | grep '^ts-' | sort -r | head -n1)
    jq -n --arg tag "$TAG" '{ tag: $tag }'
  EOT
  ]
}

# 2. Null resource tracks last synced tag and only runs when tag changes
resource "null_resource" "vault_sync_tag_tracker" {
  triggers = {
    tag = data.external.ghcr_tag.result.tag
  }
}

locals {
  image_tag = null_resource.vault_sync_tag_tracker.triggers.tag
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

resource "google_artifact_registry_repository" "thirdparty" {
  location      = var.region
  repository_id = "thirdparty"
  format        = "DOCKER"
  description   = "Third-party sidecars and base images"
  project            = google_project.infra.project_id
}

locals {
  tbot_config_yaml = templatefile("${path.module}/tbot_config/vault_tbot_config.tftpl", {
    proxy_server = "teleport.app.suncoast.systems:443"
    token_name   = "vault-bot-gcp"     # must match your Teleport token resource name
    app_name     = "vault"
    listen_addr  = "tcp://127.0.0.1:8200"
  })
  tbot_config_b64 = base64encode(local.tbot_config_yaml)
}

# --- DRY helpers ---
locals {
  app_image  = "${var.region}-docker.pkg.dev/${google_project.infra.project_id}/vault-sync-run-container/vault-sync-run-container:${local.image_tag}"
  tbot_image_digest = "sha256:a3e8181b40188685e884bc5bc8bf91bd943dc9d99b00eb2d68ad0d4ba6d37a5e"
  tbot_ghcr_image_tag = "ts-20260215-151751"
  tbot_image_name   = "teleport-bot-container"
  tbot_source_image = "ghcr.io/${var.GITHUB_ORG}/${local.tbot_image_name}:${local.tbot_ghcr_image_tag}"
  tbot_target_repo  = "${var.region}-docker.pkg.dev/${google_project.infra.project_id}/thirdparty/${local.tbot_image_name}"
  tbot_image        = "${local.tbot_target_repo}@${local.tbot_image_digest}"

  app_env = [
    { name = "VAULT_ADDRS",              value = "${var.VAULT_ADDRESS},http://127.0.0.1:8200" },
    { name = "GCP_PROJECT_ID",           value = google_project.infra.project_id },
    { name = "VAULT_CONNECT_TIMEOUT_MS", value = "300" },
    { name = "VAULT_READ_TIMEOUT_MS",    value = "2000" },
    { name = "VAULT_WAIT_FOR_TUNNEL_MS", value = "4000" },
    { name = "VAULT_ACTIVE_BASE_TTL_MS", value = "60000" },
    { name = "VAULT_PASSIVE_RECHECK_MS", value = "30000" },
    { name = "DEBUG_VAULT_RESOLVER",     value = "true" },
  ]

  tbot_env = [
    { name = "TBOT_CONFIG",      value = local.tbot_config_b64 },
    { name = "TBOT_RETRY_DELAY", value = "10" },
    # { name = "TBOT_ARGS",       value = "start" },  # default is "start"
    # { name = "TBOT_DISABLED",   value = "" },       # set "1" to park sidecar
  ]
}

resource "null_resource" "tbot_image_sync" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      GHCR_USER   = var.GITHUB_ORG
      GHCR_PAT    = var.GHCR_PAT
      PROJECT_ID  = google_project.infra.project_id
      REGION      = var.region
      SOURCE_IMG  = local.tbot_source_image
      TARGET_REPO = local.tbot_target_repo
      DIGEST      = local.tbot_image_digest
    }

    command = <<-EOT
      set -euo pipefail

      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      mkdir -p "$CLOUDSDK_CONFIG"

      # Install gcloud CLI
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"

      # Install crane (daemonless image copy tool)
      CRANE_VERSION="v0.21.3"
      OS="$(uname -s)"
      ARCH="$(uname -m)"
      case "$OS" in
        Linux) OS="Linux" ;;
        Darwin) OS="Darwin" ;;
        *) echo "Unsupported OS: $OS" && exit 1 ;;
      esac
      case "$ARCH" in
        x86_64|amd64) ARCH="x86_64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) echo "Unsupported ARCH: $ARCH" && exit 1 ;;
      esac
      CRANE_TARBALL="go-containerregistry_"$OS"_"$ARCH".tar.gz"
      CRANE_URL="https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/$CRANE_TARBALL"
      curl -fsSL "$CRANE_URL" -o "$CRANE_TARBALL"
      tar -xf "$CRANE_TARBALL"
      [ -x ./crane ] || { echo "crane binary not found after extraction"; exit 1; }
      chmod +x ./crane
      export PATH="$(pwd):$PATH"

      # Authenticate to GCP
      printf "%s" "$GOOGLE_CREDENTIALS" > key.json
      gcloud auth activate-service-account --key-file=key.json
      gcloud config set project "$PROJECT_ID"
      gcloud auth print-access-token | crane auth login "$REGION-docker.pkg.dev" -u oauth2accesstoken --password-stdin

      # Authenticate to GHCR (required if private)
      echo "$GHCR_PAT" | crane auth login ghcr.io -u "$GHCR_USER" --password-stdin

      # Check if digest already exists in Artifact Registry
      if gcloud artifacts docker images list "$TARGET_REPO" --format="get(digest)" | grep -q "$DIGEST"; then
        echo "✅ tbot image already present in Artifact Registry: $TARGET_REPO@$DIGEST"
        exit 0
      fi

      short_digest="$(echo "$DIGEST" | sed 's/^sha256://' | cut -c1-12)"
      target_tag="$TARGET_REPO:mirror-$short_digest"

      echo "🚀 Copying image to Artifact Registry: $target_tag"
      crane copy "$SOURCE_IMG" "$target_tag"

      echo "✅ tbot image synced to Artifact Registry."
    EOT
  }

  depends_on = [
    google_artifact_registry_repository.thirdparty
  ]

  triggers = {
    digest = local.tbot_image_digest
  }
}

resource "google_cloud_run_v2_service" "vault_sync_svc" {
  name                = "vault-sync-run-container"
  location            = var.region
  project             = google_project.infra.project_id
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.eventarc_service_account.email

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    # ---- App container ----
    containers {
      name  = "app"
      image = local.app_image

      dynamic "env" {
        for_each = { for i, e in local.app_env : i => e }
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      ports {
        container_port = 8080
      }

      resources {
        cpu_idle = true
      }
    }

    # ---- Teleport tbot wrapper sidecar ----
    containers {
      name  = "tbot"
      image = local.tbot_image

      dynamic "env" {
        for_each = { for i, e in local.tbot_env : i => e }
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      resources {
        limits = {
          cpu    = "200m"
          memory = "128Mi"
        }
        cpu_idle = true
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].env, # app envs may drift intentionally
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_iam_member.registry_permissions,
    google_project_iam_member.secret_manager_grant,
    null_resource.ghcr_to_gcp_image_sync,
    null_resource.tbot_image_sync,
    google_service_account.eventarc_service_account,
    google_project_iam_member.cloud_run_secret_access,
    google_project_iam_member.eventarc_receive_auditlog,
    google_kms_crypto_key_iam_member.vault_unseal_member,
    google_project_iam_member.cloud_run_secret_list,
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
    interpreter = ["/bin/bash", "-c"]

    environment = {
      GHCR_USER    = var.GITHUB_ORG
      GHCR_PAT     = var.GHCR_PAT
      PROJECT_ID   = google_project.infra.project_id
      REGION       = var.region
      IMAGE_NAME   = "vault-sync-run-container"
      TAG          = local.image_tag
    }

    command = <<-EOT
      set -euo pipefail

      export CLOUDSDK_CONFIG="$(pwd)/.gcloud"
      mkdir -p "$CLOUDSDK_CONFIG"

      # Install gcloud CLI
      curl -sS -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
      tar -xf google-cloud-cli-linux-x86_64.tar.gz
      export PATH="$(pwd)/google-cloud-sdk/bin:$PATH"

      # Install crane (daemonless image copy tool)
      CRANE_VERSION="v0.21.3"
      OS="$(uname -s)"
      ARCH="$(uname -m)"
      case "$OS" in
        Linux) OS="Linux" ;;
        Darwin) OS="Darwin" ;;
        *) echo "Unsupported OS: $OS" && exit 1 ;;
      esac
      case "$ARCH" in
        x86_64|amd64) ARCH="x86_64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) echo "Unsupported ARCH: $ARCH" && exit 1 ;;
      esac
      CRANE_TARBALL="go-containerregistry_"$OS"_"$ARCH".tar.gz"
      CRANE_URL="https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/$CRANE_TARBALL"
      curl -fsSL "$CRANE_URL" -o "$CRANE_TARBALL"
      tar -xf "$CRANE_TARBALL"
      [ -x ./crane ] || { echo "crane binary not found after extraction"; exit 1; }
      chmod +x ./crane
      export PATH="$(pwd):$PATH"

      # Authenticate to GCP
      printf "%s" "$GOOGLE_CREDENTIALS" > key.json
      gcloud auth activate-service-account --key-file=key.json
      gcloud config set project "$PROJECT_ID"
      gcloud auth print-access-token | crane auth login "$REGION-docker.pkg.dev" -u oauth2accesstoken --password-stdin

      # Authenticate to GHCR
      echo "$GHCR_PAT" | crane auth login ghcr.io -u "$GHCR_USER" --password-stdin

      # Validate vars
      if [ -z "$TAG" ] || [ -z "$IMAGE_NAME" ] || [ -z "$GHCR_USER" ]; then
        echo "❌ One or more required variables are empty: TAG=$TAG, IMAGE_NAME=$IMAGE_NAME, GHCR_USER=$GHCR_USER"
        exit 1
      fi

      GHCR_IMAGE="ghcr.io/$GHCR_USER/$IMAGE_NAME:$TAG"
      REPO_PATH="$REGION-docker.pkg.dev/$PROJECT_ID/$IMAGE_NAME/$IMAGE_NAME"

      echo "🧹 Cleaning up existing images in Artifact Registry..."
      for digest in $(gcloud artifacts docker images list "$REPO_PATH" --format="get(digest)" || true); do
        gcloud artifacts docker images delete "$REPO_PATH@$digest" --quiet --delete-tags || true
      done

      echo "🚀 Copying image to GCP Artifact Registry: $REPO_PATH:$TAG"
      crane copy "$GHCR_IMAGE" "$REPO_PATH:$TAG"

      echo "✅ GHCR image successfully pushed to GCP with tag $TAG"
    EOT
  }

  depends_on = [
    google_artifact_registry_repository.vault_sync_repo,
    null_resource.vault_sync_tag_tracker
  ]
  triggers = {
    tag = null_resource.vault_sync_tag_tracker.triggers.tag
  }

  lifecycle {
    create_before_destroy = true
  }
}
