#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /var/lib/jellyfin-bootstrap
cd /var/lib/jellyfin-bootstrap
curl --fail --silent --show-error --location --retry 5 \
  https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
  --output packages-microsoft-prod.deb
echo 'c13f01ac7c3001b51a9281d40dde666db5e037e05512840c319832f7852bfec4  packages-microsoft-prod.deb' |
  sha256sum --check --strict
dpkg --install packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
apt-get update
# Use distro Python dependencies, never the package's network pip fallback.
DEBIAN_FRONTEND=noninteractive apt-get install --yes python3-azure-identity python3-azure-core python3-yaml
AZFILESAUTH_SKIP_PIP_INSTALL=1 DEBIAN_FRONTEND=noninteractive apt-get install --yes azfilesauth=1.0-12
chown root:root /etc/azfilesauth/config.yaml
chmod 0600 /etc/azfilesauth/config.yaml
systemctl enable --now azfilesrefresh.service
