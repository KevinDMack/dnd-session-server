#!/usr/bin/env bash
set -euo pipefail

storage_type=$1
volume_id=$2

if [[ "$storage_type" == efs ]]; then
  if ! command -v mount.efs >/dev/null; then
    # AWS's supported pre-built Ubuntu installer; never fall back to plain NFS.
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
      --retry 5 https://amazon-efs-utils.aws.com/efs-utils-installer.sh \
      --output "$work/efs-utils-installer.sh"
    sh "$work/efs-utils-installer.sh" --install
  fi
  mount.efs --version
  # New mount-target DNS records can lag successful Terraform creation.
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if getent ahostsv4 "$3" >/dev/null; then exit 0; fi
    sleep 5
  done
  echo "EFS mount-target DNS did not become ready." >&2
  exit 1
fi

[[ "$storage_type" == ebs && "$volume_id" =~ ^vol-[0-9a-f]+$ ]] ||
  { echo "Invalid media storage configuration." >&2; exit 1; }

# Nitro exposes EBS volumes as NVMe devices; match the volume serial, not enumeration.
serial=${volume_id//-/}
device=
for ((attempt = 1; attempt <= 120; attempt++)); do
  device=$(lsblk --nodeps --noheadings --paths --output NAME,SERIAL |
    awk -v serial="$serial" '$2 == serial {print $1}')
  [[ -n "$device" ]] && break
  sleep 5
done
[[ -b "$device" ]] || { echo "Expected media volume did not attach." >&2; exit 1; }
[[ $(lsblk --noheadings --output NAME "$device" | wc -l) -eq 1 ]] ||
  { echo "Partitioned media disk requires explicit operator migration." >&2; exit 1; }

fs_type=$(blkid -p -s TYPE -o value "$device" || true)
if [[ -z "$fs_type" ]]; then
  # Only initialize a signature-free, unpartitioned disk, never overwrite a filesystem.
  signatures=$(wipefs --no-act --noheadings --output TYPE "$device")
  [[ -z "$signatures" ]] ||
    { echo "Unknown disk signatures; refusing initialization." >&2; exit 1; }
  mkfs.ext4 "$device"
elif [[ "$fs_type" != ext4 ]]; then
  echo "Expected ext4 media disk; refusing to modify existing data." >&2
  exit 1
fi
# The mount unit uses udev's persistent alias so systemd sees a real device unit.
alias="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$serial"
udevadm settle
[[ -b "$alias" && $(readlink -f "$alias") == "$device" ]] ||
  { echo "Expected persistent EBS device alias is missing." >&2; exit 1; }

# Set upload ownership once on the filesystem root, not on the hidden mount directory.
probe=$(mktemp -d)
cleanup() {
  if mountpoint --quiet "$probe"; then umount "$probe"; fi
  rmdir "$probe"
}
trap cleanup EXIT
mount -t ext4 -o nodev,nosuid,noexec "$device" "$probe"
chown 1000:1000 "$probe"
chmod 0755 "$probe"
