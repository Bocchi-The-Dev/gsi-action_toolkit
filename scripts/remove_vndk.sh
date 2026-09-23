#!/usr/bin/env bash
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$#" -ne 1 ]; then
    log_error "Usage: $0 <SYSTEM_DIR>"
    exit 1
fi

SYS_ROOT="$1"

log_info "Validating system directory..."
if [ ! -d "$SYS_ROOT" ]; then
    log_error "Directory does not exist: $SYS_ROOT"
    exit 1
fi

# Detect root structure
# If there is a nested 'system' directory inside the root (System-as-root), use it
if [ -d "$SYS_ROOT/system" ] && [ -d "$SYS_ROOT/system/app" ]; then
    SYS_ROOT="$SYS_ROOT/system"
    log_info "System-as-root detected. Modifying inside subfolder: $SYS_ROOT"
fi

remove_vndk_version() {
    local ver="$1"
    log_info "Processing removal of VNDK version: v${ver}..."
    
    local paths=(
        # System libraries
        "$SYS_ROOT/lib/vndk-${ver}"
        "$SYS_ROOT/lib/vndk-sp-${ver}"
        "$SYS_ROOT/lib64/vndk-${ver}"
        "$SYS_ROOT/lib64/vndk-sp-${ver}"
        # System Ext libraries
        "$SYS_ROOT/system_ext/lib/vndk-${ver}"
        "$SYS_ROOT/system_ext/lib/vndk-sp-${ver}"
        "$SYS_ROOT/system_ext/lib64/vndk-${ver}"
        "$SYS_ROOT/system_ext/lib64/vndk-sp-${ver}"
        # Apex packages
        "$SYS_ROOT/apex/com.android.vndk.v${ver}"
        "$SYS_ROOT/system_ext/apex/com.android.vndk.v${ver}"
        "$SYS_ROOT/apex/com.android.vndk.v${ver}.apex"
        "$SYS_ROOT/system_ext/apex/com.android.vndk.v${ver}.apex"
    )

    local removed_count=0
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            log_info "Removing: $path"
            sudo rm -rf "$path"
            removed_count=$((removed_count + 1))
        fi
    done
    
    if [ "$removed_count" -gt 0 ]; then
        log_success "Removed $removed_count paths related to VNDK v${ver}."
    else
        log_info "No paths found for VNDK v${ver} (already clean or not present)."
    fi
}

# Run for versions if environment variables are set to 'true'
VNDK_VERSIONS=(28 29 30 31 32 33 34)

for ver in "${VNDK_VERSIONS[@]}"; do
    var_name="REMOVE_VNDK_V${ver}"
    # Read the value of the environment variable (default to false if not set)
    val="${!var_name:-false}"
    if [ "$val" = "true" ]; then
        remove_vndk_version "$ver"
    fi
done

log_success "VNDK removal script finished."
