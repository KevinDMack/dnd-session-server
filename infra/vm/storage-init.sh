#!/usr/bin/env bash
set -euo pipefail

disk=/dev/disk/azure/scsi1/lun0
for ((attempt = 0; attempt < 150; attempt++)); do
  [[ -b "$disk" ]] && break
  sleep 2
done
[[ -b "$disk" ]] || { echo "Media LUN 0 missing; refusing to start services." >&2; exit 1; }

# Only a completely signature-free, unpartitioned, unmounted disk can be formatted.
# Existing filesystems are left untouched; partitioned/unknown layouts fail closed.
[[ "$(lsblk --noheadings --output TYPE "$disk")" == "disk" ]] ||
  { echo "Partitioned or unexpected media layout; manual recovery required." >&2; exit 1; }
if findmnt --noheadings --source "$disk" >/dev/null; then
  echo "Media disk already mounted; refusing initialization." >&2
  exit 1
fi

signatures=$(wipefs --no-act --noheadings --output TYPE "$disk")
if [[ -z "$signatures" ]]; then
  set +e
  probe=$(blkid -p "$disk" 2>&1)
  status=$?
  set -e
  [[ "$status" == 2 && -z "$probe" ]] ||
    { echo "Ambiguous disk probe; refusing to format." >&2; exit 1; }
  mkfs.ext4 -L jellyfin-media "$disk"
else
  filesystem=$(blkid -p -s TYPE -o value "$disk")
  [[ "$signatures" == ext4 && "$filesystem" == ext4 ]] ||
    { echo "Expected a whole-disk ext4 filesystem; refusing to modify existing data." >&2; exit 1; }
fi
