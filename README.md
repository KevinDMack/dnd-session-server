# dnd-session-server

Code for deploying [Jellyfin](https://jellyfin.org/) to Azure to serve our D&D session
recordings. **The recommended deployment is the Linux VM described below.**

## Recommended: Docker on an Azure VM

The independent Terraform root at `infra/vm/` uses an Ubuntu VM (East US,
`Standard_B2s` by default), a persistent OS disk for Jellyfin configuration and
accounts, and an Azure Files SMB share for recordings (512 GiB quota by default).
Only configuration/database storage needs persistent block storage: do not place
Jellyfin's SQLite database on SMB/NFS. Jellyfin sees the recordings read-only.
Cache and transcoding files remain on VM storage and are disposable.

The host mounts Azure Files using a dedicated user-assigned managed identity,
Azure Files SMB OAuth, and Microsoft's `azfilesauth` utility. There are no storage
account keys or SAS tokens in the mount configuration. This is different from
using managed identity to retrieve an account key. The managed identity needs the
documented **Storage File Data SMB MI Admin** role; it has administrative file
access, so this deployment uses a dedicated storage account rather than sharing
one with unrelated workloads.

Caddy provides HTTPS on port 443; Jellyfin's port 8096 is not publicly published.
SSH requires your public key and is restricted to your administrator CIDR. Caddy
initially restricts application requests too, so another visitor cannot claim the setup wizard.
The VM uses the official Jellyfin image, not the legacy BlobFuse image.

### Deploy

Use Terraform >= 1.9 and < 2.0, Azure CLI, an SSH key pair, and a domain whose DNS A record
you control. Your subscription must allow the VM size in your selected region.
Authenticate with `az login` and select your subscription before deployment.
The deploying principal must be able to create storage, managed identities and
role assignments as well as VMs and backup resources. Keep Terraform state and
saved plans protected; keyless runtime authentication does not make state public.
The VM must not be domain-joined. Managed-identity SMB requires Kerberos support
in the storage account's SMB settings and reachability of IMDS and the share.

From the repository directory:

```bash
cp infra/vm/terraform.tfvars.example infra/vm/terraform.tfvars
# Edit the example: subscription, domain, SSH PUBLIC key, administrator CIDR,
# budget notification email and budget start date are deployment inputs.
terraform -chdir=infra/vm init
terraform -chdir=infra/vm fmt -check
terraform -chdir=infra/vm validate
terraform -chdir=infra/vm plan -out=tfplan
terraform -chdir=infra/vm apply tfplan
terraform -chdir=infra/vm output
```

Set the domain's A record to the output public IP; remove any conflicting AAAA
record. Certificate issuance needs working public DNS and outbound internet.
Caddy uses TLS-ALPN validation on 443, not an HTTP challenge on port 80. Keep port
80 closed. The network security group permits public TCP 443 so certificate
validators can connect; Caddy's application allowlist returns 403 for other clients.
Do not restrict that network rule to your own address or certificate issuance
and renewal will fail.

SSH to the output public IP using your configured administrator user and private
key, then check bootstrap and startup:

```bash
sudo cloud-init status --wait
sudo systemctl --failed
sudo findmnt /srv/jellyfin/media
sudo azfilesauthmanager list
sudo systemctl status azfilesrefresh.service
sudo docker ps
```

Do not start Jellyfin if the SMB share has not mounted. The boot-time
authentication service must obtain credentials before mounting, and
`azfilesrefresh` renews them during operation. Initial RBAC propagation can delay
startup; check the authentication and mount unit logs rather than falling back
to account keys or creating an empty local media library. After reboot, confirm
the mount is CIFS, refresh is running, and Jellyfin can read existing recordings.

### Player accounts and first login

1. Keep Caddy's application allowlist restricted to your administrator address
   until setup is complete. Leave TCP 443 publicly reachable for certificates.
2. Open the output HTTPS URL, create a strong administrator password, and add
   `/media` as the Jellyfin library directory.
3. Create one **non-administrator** Jellyfin account per player. Grant only the
   recordings library, allow remote access, and disable deletion/administration.
   There are no per-user Jellyfin licence charges.
4. Configure Jellyfin's known reverse proxy to trust only the actual Caddy proxy
   address/network, not arbitrary client-supplied forwarding headers.
5. After setup, use `sudoedit /etc/caddy/Caddyfile` on the VM to extend the
   `@allowed remote_ip` list to the players' CIDRs, or `0.0.0.0/0` for public
   application access. Run `sudo systemctl restart caddy.service` and confirm
   player access. Never broaden SSH.

`https_allowed_cidrs` is the **initial bootstrap** allowlist, not a live update
mechanism. Changing it, the SSH administrator CIDR, or other inputs embedded in
cloud-init changes VM `custom_data`, which requires replacement. Terraform's VM
destruction guard blocks that replacement to protect accounts and certificates.
For an existing VM, maintain Caddy's runtime allowlist over SSH; leave its
bootstrap input unchanged. Review replacement plans carefully rather than
disabling the guard to make ordinary configuration changes.

There is one stateful Jellyfin instance, not a replica set. B2s is a starting
point for direct play; CPU credits and software transcoding can limit concurrent
streams. Prefer recordings that players' clients can play directly.

### Upload recordings

Upload recordings and NFO sidecars to the Azure Files share using an authorized
administrator's Azure Files client or AzCopy workflow. The VM mount is for
playback; do not assume it permits uploads, and do not grant players storage
RBAC or VM filesystem access. Preserve the library directory layout, then scan
the Jellyfin library.

The existing `scripts/upload-recordings.py` uploads to **Blob Storage only**; it
does not populate the file share. To migrate, download existing blobs using
Azure CLI/AzCopy to staging, then upload the library and NFO sidecars to Azure
Files. Your upload client's identity and network access are separate from the
VM's managed identity; a storage firewall exception or a client in the allowed
network may be necessary. Never open the share publicly to anonymous access.
The Terraform outputs `media_storage_account_name`, `media_share_name` and
`media_smb_path` identify the upload destination. The storage firewall permits the
VM subnet through a service endpoint, plus trusted Azure services for backup;
it is not an unrestricted public share.

### Backups, recovery and maintenance

The deployment provisions daily Azure Backup protection for the VM and separate
Azure Files share protection, plus a monthly cost budget email alert. **VM
backups do not contain the mounted file share.**
VM backups run at 03:00 UTC and share backups at 03:30 UTC; retention defaults
to 30 days and is configurable from 7 to 200 days.
Backup storage and protected-instance fees are additional to the estimates below.
Budget alerts are notifications, **not a spending cap or automatic shutdown**.

Share recovery points are snapshots in the source LRS storage account, **not
vaulted media copies**. The vault's geo-redundancy does not make those snapshots
geo-redundant or protect them from deletion of the storage account. Azure Backup
requires shared-key access to remain enabled on the account; the VM still uses
only managed-identity OAuth, has no `listKeys` permissions, and receives no key.

- After deployment, trigger on-demand VM and file-share backups in the Recovery
  Services vault and verify both jobs complete. Confirm the share recovery
  point exists, not just the OS disk recovery point.
- For a strictly consistent SQLite backup, stop Jellyfin before making a
  configuration copy or taking a recovery point, then start it again. Do not
  assume a live file copy or crash-consistent snapshot is application-consistent.
- Test recovery to an **isolated VM with no public ingress**: restore the OS
  disk and independently restore the share to a compatible recovery point.
  Reattach the correct user-assigned identity and confirm RBAC, network rules,
  credential acquisition and the CIFS mount before starting services. Recovered
  configuration must not accidentally point a test instance at production media.
- Check administrator/player logins, playback progress, library metadata and
  representative recordings, then switch DNS only after verification. A restored
  VM may need network and backup protection reconfigured.
- Test reboot persistence and two simultaneous player sessions before inviting
  everyone. Verify direct-play status and inspect CPU, disk, and bandwidth use.
- Keep Ubuntu security updates and container images current. Back up first,
  deliberately update pinned image versions, and check their release notes.
  Terraform bootstrap is not an in-place container upgrade mechanism.
  Container commands and immutable image references are in
  `/etc/systemd/system/jellyfin.service` and `/etc/systemd/system/caddy.service`;
  after editing them, use `sudo systemctl daemon-reload` and restart the affected
  service. Do not add Docker restart policies that bypass mount ordering.

For maintenance, use `sudo systemctl stop jellyfin.service` and
`sudo systemctl start jellyfin.service`. Both containers depend on the mounted
share. Mount/authentication failures fail closed rather than serving an empty
local directory; after repairing a mount failure, reset failed units with
`sudo systemctl reset-failed` before starting the services again. Also test
playback after credentials have renewed, not only immediately after boot.

Before intentionally removing resources, export and test backups, review Azure
Backup soft-delete/retention behavior, and understand that an OS disk deletion
removes live accounts/configuration while a share deletion removes recordings.
Do not remove destruction guards merely to make a plan succeed.

### Existing deployments: no automatic migration

`infra/vm/` has **separate Terraform state** from the original `infra/` root.
Do not copy the old state into it or reuse the original resource group's name.
Creating the VM does not destroy, modify, or stop billing for legacy resources.
Back up configuration and media before migrating; stop the old Jellyfin instance
before copying its SQLite database. Restore to a compatible Jellyfin version
and follow Jellyfin's upgrade guidance. Remove old resources only after testing
the replacement and reviewing their separate Terraform destroy plan.

If you already applied the earlier **VM + managed media disk** version of this
PR, do not apply this update blindly. Changing cloud-init requires VM replacement,
which the OS/configuration destruction guard intentionally blocks. First back up
configuration and recordings, migrate the media to Azure Files, and verify the
copied files. Plan an explicit host migration (or carefully install the new
bootstrap configuration on the existing VM). Retain the old media disk until
both playback and recovery have been tested; removing its Terraform resource
must never be treated as a data migration. An unmanaged retained disk continues
to incur charges until you explicitly delete it.
Terraform `removed` blocks deliberately forget both the old disk and its
attachment **without destroying or detaching either**. When you are ready to
retire the old disk, explicitly detach it from the old VM after migration and
backup verification, then delete it separately. Review this alongside any planned
VM replacement; do not assume the old attachment is managed by this root anymore.

## AWS alternative: EC2 with EBS or EFS

The independent Terraform root at `infra/aws/` deploys the same single-server
Jellyfin/Caddy design to AWS. It does not modify Azure resources or share their
Terraform state. Defaults are Ubuntu 24.04, `t3.medium` in `us-east-1`, a 64 GiB
encrypted gp3 root/configuration disk, and a separate 512 GiB encrypted gp3
recordings disk. Both disks remain billable when the instance is stopped.
The instance uses standard CPU credits: sustained CPU use is throttled rather
than billed as surplus credits. This is intended for direct play, not demanding
software transcoding.

Set `media_storage_type = "efs"` for a separately managed NFS filesystem instead
of an EBS media disk. Regional EFS is the default; the optional One Zone mode
has lower cost but does not tolerate loss of its Availability Zone. EFS uses an
access point, the EC2 IAM role, and encrypted TLS mounts; NFS is reachable only
from the instance security group. The instance mounts EFS read-only and receives
no media write permissions. EFS is billed for actual storage and throughput:
the EBS capacity input does **not** impose an EFS quota or spending cap.
Configuration/SQLite and Caddy certificates always stay on the EBS root disk.

### Deploy on AWS

Use Terraform >= 1.9 and < 2.0, AWS credentials for the destination account, a
public SSH key, and a hostname you control. The deploying identity needs EC2,
VPC, IAM/PassRole, Backup, Budgets, and (if selected) EFS permissions.
Authenticate using your normal AWS profile/SSO workflow, not credentials in
Terraform variables. Protect state and saved plans.

```bash
cp /home/runner/work/dnd-session-server/dnd-session-server/infra/aws/terraform.tfvars.example /home/runner/work/dnd-session-server/dnd-session-server/infra/aws/terraform.tfvars
# Edit region, public SSH key, administrator CIDR, domain, and budget recipients.
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws init
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws fmt -check
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws validate
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws plan -out=tfplan
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws apply tfplan
terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws output
```

For offline infrastructure regression checks, Terraform >= 1.12 can run
`terraform -chdir=/home/runner/work/dnd-session-server/dnd-session-server/infra/aws test`
after initialization. Tests use a mock AWS provider; they do not create resources
or replace a real boot, backup, and restore test.

Point your hostname's A record to the Elastic IP output and remove conflicting
AAAA records. DNS hosting/domain registration is not provisioned; use your
existing DNS provider. No load balancer or NAT gateway is needed.
Only TCP 443 is public; TCP 22 is limited to the administrator CIDR. Do not open
80, 8096, or NFS publicly. Caddy needs public 443 for TLS-ALPN certificate renewal
even while its application allowlist is administrator-only.

SSH as `ubuntu`, then check `sudo cloud-init status --wait`, `sudo systemctl --failed`,
`sudo findmnt /srv/jellyfin/media`, and `sudo docker ps`. EBS bootstrap waits for
the exact expected Nitro NVMe volume serial; only a signature-free,
unpartitioned disk is initialized. Other filesystems/partition layouts require
explicit migration and are never reformatted automatically.
The optional EFS bootstrap installs AWS's supported pre-built `amazon-efs-utils`
package using its HTTPS installer. This needs outbound access to
`amazon-efs-utils.aws.com` and the installer's package endpoints. The vendor
installer selects its supported package version; it is not an immutable build.
Review and maintain that package independently of the pinned container images.

Both containers require the media mount and stop when systemd deactivates it;
they never intentionally serve an empty local fallback directory. This does
not detect every remote-filesystem outage: an unreachable EFS server can leave
NFS operations blocked. If initial IAM/DNS propagation or mounting fails, fix
the cause, then use `sudo systemctl reset-failed` and
`sudo systemctl start jellyfin.service caddy.service`. Never bypass mount checks.
After reboot, verify the correct filesystem and representative playback again.

Complete the setup wizard and create separate non-administrator player accounts
before expanding `/etc/caddy/Caddyfile`'s `@allowed remote_ip` list over SSH.
Restart `caddy.service` after changes; never broaden SSH. Configure Jellyfin's
known reverse proxy to trust only the actual Caddy address/network.
Bootstrap changes request instance replacement, blocked by `prevent_destroy`.
Use deliberate runtime maintenance for existing instances, as with Azure;
changing `https_allowed_cidrs` is not a live allowlist update mechanism.

### Uploads, recovery, and migration

- **EBS:** upload recordings/NFO sidecars as `ubuntu` over SSH/SFTP into
  `/srv/jellyfin/media` only after verifying the mount. The host has write access;
  Jellyfin's container bind mount is read-only.
- **EFS:** use a separately authorized uploader inside the VPC with TLS, IAM
  `ClientMount`/`ClientWrite` permissions, and its own access point rooted at
  `/media` with UID/GID 1000. Update the filesystem resource policy explicitly
  for that uploader; the playback role must remain read-only. This root does not
  provision an upload host or expose NFS to the internet.
- The Azure Blob upload script does not support either AWS destination.
  Scan Jellyfin's library after copying and verifying the recording layout.
- AWS Backup protects the instance/disks and independently selects media storage.
  Daily backups retain recovery points for 30 days by default. Retained
  snapshots/recovery points incur additional charges; separate EC2/EBS recovery
  points can duplicate media protection. Budget emails at 80%/100% cover
  **account-wide USD spending**, including unrelated AWS resources; they are
  notifications, not a spending cap.
- Trigger on-demand backups and confirm completed recovery points for both
  configuration and recordings. Confirm AWS Backup's regional service opt-ins
  include the selected resources. EFS data is not contained in an EC2 backup.
  For a consistent SQLite recovery point, stop Jellyfin during the configuration
  backup; scheduled live snapshots are not guaranteed application-consistent.
- Test restore into an isolated instance with no public ingress using a service
  role authorized for restore (the provisioned backup role is backup-only). Restore root
  configuration/certificates and media separately, recreate attachments or EFS
  mount targets/access points and IAM permissions, and update the expected
  volume/filesystem IDs. Test mount ordering, login, playback progress, two
  concurrent streams, and reboot before changing production DNS.
- Migration is explicit: back up Azure, stop the old Jellyfin instance before
  copying its database, use compatible Jellyfin versions, copy/verify media,
  test the AWS server, then switch DNS. Azure continues billing until its
  resources are explicitly retired. Never copy Azure state into the AWS root.
- Instance, media, and backup destruction guards intentionally block routine
  replacement/deletion. The root disk is retained on termination, but this is
  not a backup. Export/test backups before a deliberate teardown; retained EBS,
  EFS, Elastic IPs and recovery points continue billing. Never disable guards
  merely to make a plan apply.

### Estimated AWS monthly costs

Planning estimates, **not live quotes**: N. Virginia, USD On-Demand Linux,
730 hours/month, 512 GiB media, direct play; no free-tier credits or commitments.

| Component | Approximate monthly cost |
| --- | ---: |
| `t3.medium` | $30.37 |
| 64 GiB gp3 root/configuration | $5.12 |
| 512 GiB gp3 media | $40.96 |
| One public IPv4 address | $3.65 |
| **Default total, before extras** | **$80.10** |
| Optional external Route 53 hosted zone | $0.50 plus queries |

With Route 53, the base is about **$80.60/month**. Replacing media EBS with EFS
One Zone Standard at roughly $0.16/GiB-month gives **$121/month**, or Regional
Standard at roughly $0.30/GiB-month gives **$193/month**, before throughput
charges. EFS storage classes/lifecycle choices can change the bill considerably.

All totals exclude backups, traffic, domains, taxes, and optional monitoring.
Standard EBS snapshot storage is approximately $0.05/GB-month of stored snapshot
data; snapshots are incremental, not 30 complete copies for 30 daily backups.
Assuming the account's first 100 GB/month internet-egress allowance is available,
then approximately $0.09/GB: 100/500/1,000 GB outbound costs about $0/$36/$81.
Stopping EC2 stops compute charges, not storage, backups, or Elastic IP charges.

Confirm current regional prices in the [AWS calculator](https://calculator.aws/),
[EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
[EBS pricing](https://aws.amazon.com/ebs/pricing/),
[EFS pricing](https://aws.amazon.com/efs/pricing/),
[VPC pricing](https://aws.amazon.com/vpc/pricing/), and
[AWS Backup pricing](https://aws.amazon.com/backup/pricing/).

## Monthly Azure cost comparison

Planning assumptions: East US, USD pay-as-you-go, 730 hours/month, approximately
512 GiB of recordings, one always-on instance, and direct play. These are **budget
estimates, not live quotes**. Confirm your region, SKUs and storage billing model
in the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

| Option | Infrastructure/month, before extras | Assessment |
| --- | ---: | --- |
| App Service Linux B2 + Azure Files | $60–70 | Not implemented: media mounting is feasible, but shared persistent storage is unsuitable for Jellyfin's SQLite database. |
| B2s VM + managed disks | $70–85 | Comparison only; the media disk has been replaced by Azure Files. |
| **B2s VM + Azure Files media** | **$70–80** | **Implemented in `infra/vm/`.** Database stays on VM disk; media uses managed-identity SMB. |

Allow roughly $30/month for B2s compute, $5–10 for OS/config storage, and $4 for
public IPv4. The Azure Files estimate assumes $0.06/GiB-month (about $31 for
512 GiB actually stored), plus transactions; confirm the selected tier and
billing model rather than treating that rate as a quote. A share quota is a
capacity limit, not necessarily the billed amount on pay-as-you-go tiers.

All figures exclude backups, disk/storage transactions, outbound traffic, optional
monitoring, domains and taxes. The implemented backups therefore make the actual
bill higher than the base table. Stopping the guest OS does not stop VM compute
billing; deallocate it in Azure, and expect disks, backups and IP charges to remain.

US internet egress planning rate: first 100 GB/month free if the allowance is
available, then approximately $0.087/GB in the next pricing band:

| Monthly outbound traffic | Approximate egress/month |
| --- | ---: |
| 100 GB | $0 |
| 500 GB | $35 |
| 1,000 GB | $78 |

Five players each watching four three-hour sessions at 5 Mbps generate about
135 GB/month before overhead or repeat viewing. Storage growth and playback
traffic should drive budget changes.

Sources: Azure [VMs](https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/),
[App Service](https://azure.microsoft.com/en-us/pricing/details/app-service/linux/),
[managed disks](https://azure.microsoft.com/en-us/pricing/details/managed-disks/),
[Files](https://azure.microsoft.com/en-us/pricing/details/storage/files/),
[bandwidth](https://azure.microsoft.com/en-us/pricing/details/bandwidth/), and
[Jellyfin storage guidance](https://jellyfin.org/docs/general/administration/storage/).
Managed-identity mounting:
[Microsoft Azure Files guide](https://learn.microsoft.com/en-us/azure/storage/files/files-managed-identities?pivots=linux)
and [AzFilesAuthenticator](https://github.com/Azure/AzFilesAuthenticator).

## Legacy deployment (not recommended)

The original `infra/` root attempts to run Jellyfin as an Azure Container App.
It is retained for reference, **not a working deployment recommendation**:
BlobFuse needs privileges/device access unavailable in this platform, and the
SQLite database should not live on an SMB/NFS share.

The original architecture is:

* the **video files** live in an Azure Blob Storage container which is mounted inside the
  container with **BlobFuse2** using a **user assigned managed identity** (no keys in the
  image or in the app configuration);
* the **`/config` directory** (Jellyfin database, metadata and settings) is persisted on an
  **Azure Files** share mounted as a Container Apps volume, so state survives restarts and
  new revisions.

### Legacy repository structure

```
jellyfin-azure/
├─ infra/                      Terraform for the Azure infrastructure
│  ├─ main.tf                  storage, managed identity, registry, container app
│  ├─ variables.tf
│  ├─ outputs.tf
│  └─ provider.tf
├─ app/                        Jellyfin container image
│  ├─ Dockerfile               Jellyfin + BlobFuse2
│  ├─ entrypoint.sh            mounts the blob container, then starts Jellyfin
│  ├─ docker-compose.yml       local run
│  └─ jellyfin.env.example
├─ scripts/
│  ├─ mount-azure-files.sh     mount the /config share locally
│  ├─ create-azure-files-share.sh
│  ├─ upload-recordings.py     upload videos with Jellyfin metadata
│  └─ recordings.example.json  metadata manifest example
├─ .devcontainer/              Terraform + Azure CLI + BlobFuse2 dev container
│  ├─ devcontainer.json
│  └─ Dockerfile
├─ .vscode/
│  ├─ launch.json
│  └─ tasks.json
└─ README.md
```

### Legacy getting started (reference only)

1. Open the repository in VS Code and **Reopen in Container**. The dev container ships with
   Terraform, the Azure CLI, BlobFuse2, `cifs-utils`, `jq` and `shellcheck`.
2. Sign in: `az login` and `az account set --subscription <id>`.
3. Configure the deployment:

   ```bash
   cd infra
   cp terraform.tfvars.example terraform.tfvars   # then edit it
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

4. Build and push the Jellyfin image into the registry created by Terraform:

   ```bash
   az acr build \
     --registry "$(terraform -chdir=infra output -raw container_registry_name)" \
     --image jellyfin-blobfuse:latest \
     app
   ```

   Re-run `terraform apply` (or `az containerapp update`) after pushing a new image tag.

5. Browse to `terraform output jellyfin_url`.

Equivalent VS Code tasks (`Terminal → Run Task`) and launch configurations are provided in
`.vscode/`.

### What legacy Terraform creates

| Resource | Purpose |
| --- | --- |
| Resource group | Holds everything below |
| Storage account | Blob container for video files + file share for `/config` |
| User assigned managed identity | Blob data access, file data access and `AcrPull` |
| Container registry | Hosts the Jellyfin + BlobFuse2 image |
| Log Analytics workspace | Container Apps logs |
| Container Apps environment + Azure Files storage | Runtime and the `/config` volume |
| Container app | Jellyfin, single replica, HTTPS ingress on port 8096 |

The identity is granted `Storage Blob Data Contributor` and
`Storage File Data SMB Share Contributor` on the storage account, and `AcrPull` on the
registry.

### Legacy media storage

`app/entrypoint.sh` generates a BlobFuse2 configuration at start-up and mounts
`https://<account>.blob.core.windows.net/<container>` at `MEDIA_MOUNT_PATH` (default
`/media`) using `mode: msi` with the managed identity client ID supplied through
`AZURE_CLIENT_ID`. Add `/media` as a library folder in the Jellyfin setup wizard.

Upload recordings and generate Jellyfin-compatible NFO metadata from a JSON manifest:

```bash
cp scripts/recordings.example.json recordings.json
# Edit recordings.json so each "file" is relative to the local recordings folder.

python scripts/upload-recordings.py ./recordings ./recordings.json \
  --account-name "$(terraform -chdir=infra output -raw storage_account_name)" \
  --container-name "$(terraform -chdir=infra output -raw media_container_name)"
```

The script uses the current Azure CLI login (`az login`) and creates a TV library layout:
`<series>/Season <number>/S<number>E<number> - <title>.<extension>`. It uploads
`tvshow.nfo` and episode NFO sidecars so Jellyfin can read the title, overview, dates,
runtime, genres, and tags from the manifest. Four files upload in parallel by default, with
a completed/total progress update after each file. Set the concurrency with `--workers`,
use `--dry-run` to validate and preview all destinations, or use `--overwrite` to replace
blobs that already exist. After uploading, scan the Jellyfin library to load the new files.

FUSE requires `SYS_ADMIN` and `/dev/fuse`; both are configured for local runs in
`app/docker-compose.yml`.

### Legacy configuration storage

The `/config` volume is the Azure Files share created by Terraform. Inspect or seed it from
the dev container:

```bash
sudo -E ./scripts/mount-azure-files.sh \
  -g "$(terraform -chdir=infra output -raw resource_group_name)" \
  -a "$(terraform -chdir=infra output -raw storage_account_name)"
```

`scripts/create-azure-files-share.sh` recreates the share (and the blob container) outside
of Terraform when needed.

### Legacy local development

```bash
cd app
cp jellyfin.env.example jellyfin.env   # fill in the values from terraform output
docker compose up --build
```

Local runs authenticate to Azure with whatever identity is available to the container; when
`STORAGE_ACCOUNT_NAME`/`MEDIA_CONTAINER_NAME` are left empty the BlobFuse2 mount is skipped
and Jellyfin starts with local storage only.

## Validation

For the recommended VM deployment:

```bash
terraform -chdir=infra/vm init -backend=false
terraform -chdir=infra/vm fmt -check
terraform -chdir=infra/vm validate
terraform -chdir=infra/vm test
shellcheck infra/vm/media-auth.sh infra/vm/install-azfilesauth.sh
bash -n infra/vm/media-auth.sh
bash -n infra/vm/install-azfilesauth.sh
```

The mocked Terraform tests require Terraform >= 1.12 and do not need Azure
credentials; deployment supports >= 1.9. Terraform validation
and mocked plans do not deploy resources or prove that Azure bootstrap,
certificate issuance, backup recovery, or player playback work. Perform the
deployment acceptance checks above in your subscription.

For the unchanged legacy deployment:

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
shellcheck scripts/*.sh app/entrypoint.sh
```
