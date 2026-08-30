FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ARG TERRAFORM_VERSION=1.9.8

# Tools used by the Terraform configuration and the helper scripts
RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        gnupg \
        jq \
        shellcheck \
        cifs-utils \
        fuse3 \
    && rm -rf /var/lib/apt/lists/*

# Terraform CLI
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/terraform.zip \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
    && unzip -d /usr/local/bin /tmp/terraform.zip \
    && rm /tmp/terraform.zip \
    && terraform version

# Azure CLI
RUN curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash

# BlobFuse2, so the same mount commands used by the container image can be
# exercised locally from the dev container.
RUN curl -fsSL -o /tmp/packages-microsoft-prod.deb \
        https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends blobfuse2 \
    && rm -rf /var/lib/apt/lists/*
