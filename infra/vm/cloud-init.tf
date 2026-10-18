locals {
  # Official stable releases verified 2026-10-17; digests make pulls immutable.
  jellyfin_image = "jellyfin/jellyfin:12.2.20261005-225228@sha256:357724bf0ae27a672c7cbaa899db2d9abeb13dbd8657ccce750258a4c059d037"
  caddy_image    = "caddy:2.11.7@sha256:685ae3d7c34d9b5f8caeddc5d14051db7bbd88ff1f5a2fa0c16bd8ca328fb7af"
  https_cidrs    = var.https_allowed_cidrs == null ? [var.administrator_cidr] : var.https_allowed_cidrs
  services = {
    jellyfin = {
      image = local.jellyfin_image
      args  = "--user 1000:1000 --publish 127.0.0.1:8096:8096 --mount type=bind,src=/srv/jellyfin/config,dst=/config --mount type=bind,src=/var/cache/jellyfin,dst=/cache --mount type=bind,src=/srv/jellyfin/media,dst=/media,readonly --security-opt no-new-privileges --cap-drop ALL"
    }
    caddy = {
      image = local.caddy_image
      args  = "--network host --mount type=bind,src=/etc/caddy/Caddyfile,dst=/etc/caddy/Caddyfile,readonly --mount type=bind,src=/srv/caddy/data,dst=/data --mount type=bind,src=/srv/caddy/config,dst=/config --security-opt no-new-privileges --cap-drop ALL --cap-add NET_BIND_SERVICE"
    }
  }
  cloud_init = "#cloud-config\n${yamlencode({
    package_update = true
    packages       = ["docker.io", "cifs-utils", "curl", "util-linux"]
    ssh_pwauth     = false
    disable_root   = true
    write_files = concat([
      {
        path        = "/usr/local/sbin/jellyfin-media-auth"
        permissions = "0755"
        encoding    = "b64"
        content     = filebase64("${path.module}/media-auth.sh")
      },
      {
        path        = "/usr/local/sbin/jellyfin-install-azfilesauth"
        permissions = "0755"
        encoding    = "b64"
        content     = filebase64("${path.module}/install-azfilesauth.sh")
      },
      {
        path        = "/etc/systemd/system/jellyfin-media-auth.service"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/media-auth.service.tftpl", {
          endpoint  = local.media_endpoint
          client_id = azurerm_user_assigned_identity.media.client_id
          share     = azurerm_storage_share.media.name
        }))
      },
      {
        path        = "/etc/systemd/system/srv-jellyfin-media.mount"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/media.mount.tftpl", {
          endpoint  = local.media_endpoint
          share     = azurerm_storage_share.media.name
          client_id = azurerm_user_assigned_identity.media.client_id
        }))
      },
      {
        path        = "/etc/caddy/Caddyfile"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/Caddyfile.tftpl", {
          domain_name = var.domain_name
          https_cidrs = join(" ", local.https_cidrs)
        }))
      },
      {
        path        = "/etc/ssh/sshd_config.d/00-jellyfin-hardening.conf"
        permissions = "0644"
        encoding    = "b64"
        content     = base64encode("PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n")
      }
      ], [for name, service in local.services : {
        path        = "/etc/systemd/system/${name}.service"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/container.service.tftpl", {
          name  = name
          image = service.image
          args  = service.args
        }))
    }])
    runcmd = [
      ["install", "-d", "-m", "0755", "/srv/jellyfin/media", "/srv/jellyfin/config", "/var/cache/jellyfin", "/srv/caddy/data", "/srv/caddy/config"],
      ["chown", "1000:1000", "/srv/jellyfin/config", "/var/cache/jellyfin"],
      ["/usr/local/sbin/jellyfin-install-azfilesauth"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "docker.service"],
      ["systemctl", "enable", "--now", "jellyfin.service", "caddy.service"],
      ["systemctl", "reload", "ssh.service"]
    ]
  })}"
}
