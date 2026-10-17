#!/usr/bin/env bash
set -euo pipefail

endpoint=$1
client_id=$2
share=$3
probe=/run/jellyfin-media-probe
install -d -m 0700 "$probe"
cleanup() {
  if mountpoint --quiet "$probe"; then
    umount "$probe"
  fi
}
trap cleanup EXIT

# Reacquire tickets on every boot; refresh alone cannot bootstrap an empty cache.
# Role assignment/IMDS propagation can lag VM provisioning by several minutes.
for ((attempt = 1; attempt <= 60; attempt++)); do
  if azfilesauthmanager set "https://$endpoint" --imds-client-id "$client_id"; then
    cruid=$(awk '/^USER_UID:/{print $2}' /etc/azfilesauth/config.yaml)
    [[ "$cruid" =~ ^[0-9]+$ && "$cruid" == "$(id -u azfilesuser)" ]] ||
      { echo "Unexpected Azure Files credential owner; refusing mount." >&2; exit 1; }
    # A cached OAuth ticket alone does not prove SMB RBAC has propagated.
    # Probe the share read-only before allowing systemd's real mount to start.
    if timeout --kill-after=5 20 mount -t cifs "//$endpoint/$share" "$probe" \
      -o "ro,username=$client_id,sec=krb5,cruid=$cruid,vers=3.1.1,seal,nosharesock,nodev,nosuid,noexec"; then
      umount "$probe"
      exit 0
    fi
    cleanup
  fi
  sleep 15
done
echo "Azure Files managed identity authentication failed; refusing media startup." >&2
exit 1
