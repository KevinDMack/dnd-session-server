#!/usr/bin/env bash
# Creates (idempotently) the Azure Files share used to persist the Jellyfin
# /config directory, and the blob container used for the video files.
#
# Terraform creates both by default; this script is useful when the share has to
# be recreated or when a second share/container is needed.
#
# Usage:
#   ./create-azure-files-share.sh -g <resource-group> -a <storage-account> \
#       [-s <share-name>] [-q <quota-gb>] [-c <blob-container-name>]
set -euo pipefail

SHARE_NAME="jellyfin-config"
QUOTA_GB="100"
CONTAINER_NAME="media"
RESOURCE_GROUP=""
ACCOUNT_NAME=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts ":g:a:s:q:c:h" opt; do
  case "${opt}" in
  g) RESOURCE_GROUP="${OPTARG}" ;;
  a) ACCOUNT_NAME="${OPTARG}" ;;
  s) SHARE_NAME="${OPTARG}" ;;
  q) QUOTA_GB="${OPTARG}" ;;
  c) CONTAINER_NAME="${OPTARG}" ;;
  h) usage 0 ;;
  *) usage 1 ;;
  esac
done

if [[ -z "${RESOURCE_GROUP}" || -z "${ACCOUNT_NAME}" ]]; then
  echo "error: -g <resource-group> and -a <storage-account> are required" >&2
  usage 1
fi

echo "Ensuring file share '${SHARE_NAME}' (${QUOTA_GB} GiB) exists in ${ACCOUNT_NAME}"
az storage share-rm create \
  --resource-group "${RESOURCE_GROUP}" \
  --storage-account "${ACCOUNT_NAME}" \
  --name "${SHARE_NAME}" \
  --quota "${QUOTA_GB}" \
  --output none

echo "Ensuring blob container '${CONTAINER_NAME}' exists in ${ACCOUNT_NAME}"
az storage container create \
  --account-name "${ACCOUNT_NAME}" \
  --name "${CONTAINER_NAME}" \
  --auth-mode login \
  --output none

echo "Done."
