#/bin/bash

# repo: GitHub repository in the format "owner/repo"
# asset_type: extension of the asset to download (e.g., "deb", "tar.gz")

# Set repo
REPO="$1"
ASSET_TYPE="$2"
DEST="$3"

# Detect OS, version, and architecture
OS_ID=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
OS_VERSION_ID=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
ARCH=$(dpkg --print-architecture)

# Fallback if VERSION_CODENAME is not set
if [ -z "$OS_VERSION_ID" ]; then
    OS_VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
fi

# Compose asset pattern for mergerfs deb package
ASSET_PATTERN="mergerfs_.*\\.${OS_ID}-${OS_VERSION_ID}_${ARCH}\\.${ASSET_TYPE}"
# Example
# https://github.com/trapexit/mergerfs/releases/download/2.41.1/mergerfs_2.41.1.debian-bookworm_amd64.deb


# Get latest release info from GitHub API
API_URL="https://api.github.com/repos/$REPO/releases/latest"
# Extract the asset URL using grep and the asset pattern
ASSET_URL=$(curl -s "$API_URL" | grep 'browser_download_url' | grep -Eo 'https://[^" ]+' | grep -E "$ASSET_PATTERN" | head -n 1)

if [ -z "$ASSET_URL" ]; then
    echo "Could not find asset matching pattern: $ASSET_PATTERN"
    exit 1
fi

echo "Downloading: $ASSET_URL"
curl -L -o "$DEST/$(basename "$ASSET_URL")" "$ASSET_URL"
