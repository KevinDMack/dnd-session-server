# Jellyfin with BlobFuse2 so the video library can live in Azure Blob Storage
# and be accessed with a managed identity.
FROM jellyfin/jellyfin:10.10.3

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL -o /tmp/packages-microsoft-prod.deb \
        https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends blobfuse2 fuse3 \
    && rm -rf /var/lib/apt/lists/*

# Required so the Jellyfin process can read the FUSE mount created by root.
RUN echo "user_allow_other" >> /etc/fuse.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /config is backed by an Azure Files volume, /media by BlobFuse2.
ENV MEDIA_MOUNT_PATH=/media \
    BLOBFUSE_TMP_PATH=/var/cache/blobfuse2 \
    JELLYFIN_CONFIG_DIR=/config/config \
    JELLYFIN_DATA_DIR=/config/data \
    JELLYFIN_CACHE_DIR=/config/cache

EXPOSE 8096

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
