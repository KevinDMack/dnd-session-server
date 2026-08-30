# dnd-session-server

Code for deploying [Jellyfin](https://jellyfin.org/) to Azure to serve our D&D session
recordings.

Jellyfin runs as an Azure Container App:

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
runtime, genres, and tags from the manifest. Use `--dry-run` to validate and preview all
destinations, or `--overwrite` to replace blobs that already exist. After uploading, scan
the Jellyfin library to load the new files.

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
