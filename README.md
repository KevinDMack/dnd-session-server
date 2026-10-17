# dnd-session-server

Code for deploying [Jellyfin](https://jellyfin.org/) to Azure to serve our D&D session
recordings. **The recommended deployment is the Linux VM described below.**

## Recommended: Docker on an Azure VM

The independent Terraform root at `infra/vm/` uses an Ubuntu VM (East US,
`Standard_B2s` by default), a persistent OS disk for Jellyfin configuration and
accounts, and a separate 512 GiB Standard SSD managed disk for recordings. These
are persistent block devices, not Azure temporary/resource disks. Jellyfin sees
the recordings read-only. Cache and transcoding files are disposable.

Caddy provides HTTPS on port 443; Jellyfin's port 8096 is not publicly published.
SSH requires your public key and is restricted to your administrator CIDR. HTTPS
is initially restricted too, so another visitor cannot claim the setup wizard.
The VM uses the official Jellyfin image, not the legacy BlobFuse image.

### Deploy

Use Terraform >= 1.5, Azure CLI, an SSH key pair, and a domain whose DNS A record
you control. Your subscription must allow the VM size in your selected region.
Authenticate with `az login` and select your subscription before deployment.

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
80 closed. Follow the certificate-validation network instructions in the example
variables before expecting a certificate.

SSH to the output public IP using your configured administrator user and private
key, then check bootstrap and startup:

```bash
sudo cloud-init status --wait
sudo systemctl --failed
sudo lsblk -f
sudo findmnt /srv/jellyfin/media
sudo docker ps
```

Do not upload media or start Jellyfin if the media disk has not mounted. Disk
initialization must not be repeated manually on an existing disk.

### Player accounts and first login

1. Keep HTTPS restricted to your administrator address until setup is complete.
   If certificate issuance requires temporarily public 443, keep Caddy/Jellyfin
   access restricted as described in the deployment configuration.
2. Open the output HTTPS URL, create a strong administrator password, and add
   `/media` as the Jellyfin library directory.
3. Create one **non-administrator** Jellyfin account per player. Grant only the
   recordings library, allow remote access, and disable deletion/administration.
   There are no per-user Jellyfin licence charges.
4. Configure Jellyfin's known reverse proxy to trust only the actual Caddy proxy
   address/network, not arbitrary client-supplied forwarding headers.
5. After setup, expand `https_allowed_cidrs` to the players' addresses, or to
   `["0.0.0.0/0"]` for public HTTPS, and apply Terraform again. Never broaden SSH.

There is one stateful Jellyfin instance, not a replica set. B2s is a starting
point for direct play; CPU credits and software transcoding can limit concurrent
streams. Prefer recordings that players' clients can play directly.

### Upload recordings

Copy recordings over SSH to the VM's `/srv/jellyfin/media/` directory, using
`sudo` to move files from the administrator's staging directory as necessary.
Ensure directories are readable/traversable and files readable by Jellyfin.
Then scan the library. Do not grant players filesystem access.

The existing `scripts/upload-recordings.py` uploads to **Blob Storage only**; it
does not populate the new managed disk. To migrate, download existing blobs using
Azure CLI/AzCopy to staging, then copy the library and NFO sidecars onto the media
disk. The new deployment does not require BlobFuse or SMB credentials.

### Backups, recovery and maintenance

The VM deployment provisions Azure Backup with daily backups and retention,
including the attached recordings disk, plus a monthly cost budget email alert.
Backup storage and protected-instance fees are additional to the estimates below.
Budget alerts are notifications, **not a spending cap or automatic shutdown**.

- After deployment, trigger an on-demand backup in the Recovery Services vault
  and verify the job completes and includes both disks.
- For a strictly consistent SQLite backup, stop Jellyfin before making a
  configuration copy or taking a recovery point, then start it again. Do not
  assume a live file copy or crash-consistent snapshot is application-consistent.
- Test recovery to an **isolated VM with no public ingress**: restore both OS
  and data disks from the same recovery point using Azure Backup, attach the
  media disk at LUN 0, and verify the mount before starting services.
- Check administrator/player logins, playback progress, library metadata and
  representative recordings, then switch DNS only after verification. A restored
  VM may need network and backup protection reconfigured.
- Test reboot persistence and two simultaneous player sessions before inviting
  everyone. Verify direct-play status and inspect CPU, disk, and bandwidth use.
- Keep Ubuntu security updates and container images current. Back up first,
  deliberately update pinned image versions, and check their release notes.
  Terraform bootstrap is not an in-place container upgrade mechanism.

The managed media disk has a Terraform destruction guard. Do not remove it merely
to make a plan succeed. Before intentionally removing resources, export and test
backups, review Azure Backup soft-delete/retention behavior, and understand that
an OS disk deletion also removes the live accounts and configuration.

### Existing deployments: no automatic migration

`infra/vm/` has **separate Terraform state** from the original `infra/` root.
Do not copy the old state into it or reuse the original resource group's name.
Creating the VM does not destroy, modify, or stop billing for legacy resources.
Back up configuration and media before migrating; stop the old Jellyfin instance
before copying its SQLite database. Restore to a compatible Jellyfin version
and follow Jellyfin's upgrade guidance. Remove old resources only after testing
the replacement and reviewing their separate Terraform destroy plan.

## Monthly Azure cost comparison

Planning assumptions: East US, USD pay-as-you-go, 730 hours/month, approximately
512 GiB of recordings, one always-on instance, and direct play. These are **budget
estimates, not live quotes**. Confirm your region, SKUs and storage billing model
in the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

| Option | Infrastructure/month, before extras | Assessment |
| --- | ---: | --- |
| App Service Linux B2 + Azure Files | $60–70 | Not implemented: media mounting is feasible, but shared persistent storage is unsuitable for Jellyfin's SQLite database. |
| **B2s VM + managed disks** | **$70–85** | **Implemented in `infra/vm/`.** Persistent block storage for database and media. |
| B2s VM + Azure Files media | $70–80 | Comparison only; keep the database on VM disk. Adds SMB setup and transaction charges. |

Allow roughly $30/month for B2s compute, $5–10 for OS/config storage, $30–40
for a provisioned 512 GiB Standard SSD media disk, and $4 for public IPv4.
The Azure Files comparison assumes $0.06/GiB-month plus transactions; confirm the
selected tier rather than treating that rate as a quote.

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

## Repository structure

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

## Getting started

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

## What Terraform creates

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

## Media storage

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

## Configuration storage

The `/config` volume is the Azure Files share created by Terraform. Inspect or seed it from
the dev container:

```bash
sudo -E ./scripts/mount-azure-files.sh \
  -g "$(terraform -chdir=infra output -raw resource_group_name)" \
  -a "$(terraform -chdir=infra output -raw storage_account_name)"
```

`scripts/create-azure-files-share.sh` recreates the share (and the blob container) outside
of Terraform when needed.

## Running locally

```bash
cd app
cp jellyfin.env.example jellyfin.env   # fill in the values from terraform output
docker compose up --build
```

Local runs authenticate to Azure with whatever identity is available to the container; when
`STORAGE_ACCOUNT_NAME`/`MEDIA_CONTAINER_NAME` are left empty the BlobFuse2 mount is skipped
and Jellyfin starts with local storage only.

## Checks

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
shellcheck scripts/*.sh app/entrypoint.sh
```
