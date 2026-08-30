#!/usr/bin/env bash
# Mounts the Jellyfin /config Azure Files share on the local machine (or in the
# dev container) so its contents can be inspected or seeded.
#
# The Azure Container Apps environment mounts the same share as the /config
# volume of the Jellyfin container.
#
# Usage:
#   sudo -E ./mount-azure-files.sh -g <resource-group> -a <storage-account> \
#       [-s <share-name>] [-m <mount-point>]
set -euo pipefail

SHARE_NAME="jellyfin-config"
MOUNT_POINT="/mnt/jellyfin-config"
RESOURCE_GROUP=""
ACCOUNT_NAME=""

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts ":g:a:s:m:h" opt; do
  case "${opt}" in
  g) RESOURCE_GROUP="${OPTARG}" ;;
  a) ACCOUNT_NAME="${OPTARG}" ;;
  s) SHARE_NAME="${OPTARG}" ;;
  m) MOUNT_POINT="${OPTARG}" ;;
  h) usage 0 ;;
  *) usage 1 ;;
  esac
done

if [[ -z "${RESOURCE_GROUP}" || -z "${ACCOUNT_NAME}" ]]; then
  echo "error: -g <resource-group> and -a <storage-account> are required" >&2
  usage 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: mounting SMB requires root, re-run with sudo -E" >&2
  exit 1
fi

CREDENTIALS_FILE="$(mktemp)"
cleanup() { rm -f "${CREDENTIALS_FILE}"; }
trap cleanup EXIT
chmod 600 "${CREDENTIALS_FILE}"

# SMB mounts cannot use a managed identity, so the storage account key is read
# (never printed) into a root-only credentials file for the mount call.
ACCOUNT_KEY="$(az storage account keys list \
  --resource-group "${RESOURCE_GROUP}" \
  --account-name "${ACCOUNT_NAME}" \
  --query "[0].value" \
  --output tsv)"

{
  echo "username=${ACCOUNT_NAME}"
  printf '%s\n' "password=${ACCOUNT_KEY}"
} >"${CREDENTIALS_FILE}"
unset ACCOUNT_KEY

mkdir -p "${MOUNT_POINT}"

echo "Mounting //${ACCOUNT_NAME}.file.core.windows.net/${SHARE_NAME} at ${MOUNT_POINT}"
mount -t cifs "//${ACCOUNT_NAME}.file.core.windows.net/${SHARE_NAME}" "${MOUNT_POINT}" \
  -o "credentials=${CREDENTIALS_FILE},serverino,nosharesock,actimeo=30,mfsymlinks,vers=3.1.1,dir_mode=0777,file_mode=0777"

echo "Mounted. Unmount with: sudo umount ${MOUNT_POINT}"
