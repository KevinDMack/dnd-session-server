#!/usr/bin/env bash
# Mounts the Azure Blob Storage media container with BlobFuse2 (managed identity
# authentication) and then starts Jellyfin.
set -euo pipefail

STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
MEDIA_CONTAINER_NAME="${MEDIA_CONTAINER_NAME:-}"
MEDIA_MOUNT_PATH="${MEDIA_MOUNT_PATH:-/media}"
BLOBFUSE_TMP_PATH="${BLOBFUSE_TMP_PATH:-/var/cache/blobfuse2}"
STORAGE_BLOB_ENDPOINT="${STORAGE_BLOB_ENDPOINT:-https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"

log() { echo "[entrypoint] $*"; }

mount_media() {
  local config_file="/tmp/blobfuse2.yaml"

  mkdir -p "${MEDIA_MOUNT_PATH}" "${BLOBFUSE_TMP_PATH}"

  cat >"${config_file}" <<EOF
allow-other: true
logging:
  type: base
  level: log_warning
components:
  - libfuse
  - file_cache
  - attr_cache
  - azstorage
libfuse:
  attribute-expiration-sec: 120
  entry-expiration-sec: 120
  negative-entry-expiration-sec: 120
file_cache:
  path: ${BLOBFUSE_TMP_PATH}
  timeout-sec: 120
attr_cache:
  timeout-sec: 7200
azstorage:
  type: block
  account-name: ${STORAGE_ACCOUNT_NAME}
  endpoint: ${STORAGE_BLOB_ENDPOINT}
  container: ${MEDIA_CONTAINER_NAME}
  mode: msi
  appid: ${AZURE_CLIENT_ID}
EOF
  chmod 600 "${config_file}"

  log "mounting ${STORAGE_ACCOUNT_NAME}/${MEDIA_CONTAINER_NAME} at ${MEDIA_MOUNT_PATH}"
  blobfuse2 mount "${MEDIA_MOUNT_PATH}" --config-file="${config_file}"
}

unmount_media() {
  if mountpoint -q "${MEDIA_MOUNT_PATH}"; then
    log "unmounting ${MEDIA_MOUNT_PATH}"
    blobfuse2 unmount "${MEDIA_MOUNT_PATH}" || true
  fi
}

if [[ -n "${STORAGE_ACCOUNT_NAME}" && -n "${MEDIA_CONTAINER_NAME}" ]]; then
  trap unmount_media EXIT
  mount_media
else
  log "STORAGE_ACCOUNT_NAME/MEDIA_CONTAINER_NAME not set, skipping BlobFuse2 mount"
fi

# /config is backed by the Azure Files volume; make sure the Jellyfin sub
# directories exist before the server starts.
mkdir -p "${JELLYFIN_CONFIG_DIR:-/config/config}" \
  "${JELLYFIN_DATA_DIR:-/config/data}" \
  "${JELLYFIN_CACHE_DIR:-/config/cache}"

log "starting Jellyfin"
exec /jellyfin/jellyfin "$@"
