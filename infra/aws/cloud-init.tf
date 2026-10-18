locals {
  jellyfin_image = "jellyfin/jellyfin:12.2.20261005-225228@sha256:357724bf0ae27a672c7cbaa899db2d9abeb13dbd8657ccce750258a4c059d037"
  caddy_image    = "caddy:2.11.7@sha256:685ae3d7c34d9b5f8caeddc5d14051db7bbd88ff1f5a2fa0c16bd8ca328fb7af"
  https_cidrs    = var.https_allowed_cidrs == null ? [var.administrator_cidr] : var.https_allowed_cidrs
  media_source   = var.media_storage_type == "ebs" ? "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.media[0].id, "-", "")}" : "${aws_efs_file_system.media[0].id}:/"
  media_options = var.media_storage_type == "ebs" ? "defaults,nodev,nosuid,noexec" : join(",", [
    "_netdev", "ro", "tls", "iam", "accesspoint=${aws_efs_access_point.media[0].id}", "nodev", "nosuid", "noexec"
  ])
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
    packages       = ["docker.io", "curl", "ca-certificates", "nfs-common", "util-linux", "e2fsprogs"]
    ssh_pwauth     = false
    disable_root   = true
    write_files = concat([
      {
        path        = "/usr/local/sbin/jellyfin-prepare-media"
        permissions = "0755"
        encoding    = "b64"
        content     = filebase64("${path.module}/prepare-media.sh")
      },
      {
        path        = "/etc/systemd/system/jellyfin-prepare-media.service"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/prepare-media.service.tftpl", {
          storage_type = var.media_storage_type
          volume_id    = var.media_storage_type == "ebs" ? aws_ebs_volume.media[0].id : "none"
          efs_dns      = var.media_storage_type == "efs" ? aws_efs_file_system.media[0].dns_name : "none"
        }))
      },
      {
        path        = "/etc/systemd/system/srv-jellyfin-media.mount"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/media.mount.tftpl", {
          source  = local.media_source
          fs_type = var.media_storage_type == "ebs" ? "ext4" : "efs"
          options = local.media_options
        }))
      },
      {
        path        = "/etc/caddy/Caddyfile"
        permissions = "0644"
        encoding    = "b64"
        content = base64encode(templatefile("${path.module}/../vm/Caddyfile.tftpl", {
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
        content = base64encode(templatefile("${path.module}/../vm/container.service.tftpl", {
          name  = name
          image = service.image
          args  = service.args
        }))
    }])
    runcmd = [
      ["install", "-d", "-m", "0755", "/srv/jellyfin/media", "/srv/jellyfin/config", "/var/cache/jellyfin", "/srv/caddy/data", "/srv/caddy/config"],
      ["chown", "1000:1000", "/srv/jellyfin/config", "/var/cache/jellyfin"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "docker.service"],
      ["systemctl", "enable", "--now", "jellyfin.service", "caddy.service"],
      ["systemctl", "reload", "ssh.service"]
    ]
  })}"
}
