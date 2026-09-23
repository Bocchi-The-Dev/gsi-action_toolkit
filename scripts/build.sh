#!/usr/bin/env bash
set -euo pipefail

# Pretty Logging
ARROW="\033[1;34m==>\033[0m"
TICK="\033[0;32m✓\033[0m"

log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

log_header() { echo -e "${ARROW} $*..."; }
log_step_success() { echo -e "${TICK} $*"; }

run_cmd() {
    local log_file
    log_file=$(mktemp)
    if ! "$@" > "$log_file" 2>&1; then
        echo -e "\n\033[0;31m[ERROR] Command failed: $*\033[0m"
        echo "----------------------------------------"
        cat "$log_file"
        echo "----------------------------------------"
        rm -f "$log_file"
        exit 1
    fi
    rm -f "$log_file"
}

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORKSPACE_DIR="workspace"
EXTRACT_DIR="$WORKSPACE_DIR/extracted"
SYS_DIR="$WORKSPACE_DIR/sys_dir"
INPUT_IMAGE="$WORKSPACE_DIR/system.img"
OUTPUT_IMAGE="$WORKSPACE_DIR/system_new.img"

log_info "Initializing GSI Builder..."

# Validate GSI URL
if [ -z "${GSI_URL:-}" ]; then
    log_error "GSI_URL environment variable is required."
    exit 1
fi

OUTPUT_FS="${OUTPUT_FS:-ext4}"
COMPRESS_OUTPUT="${COMPRESS_OUTPUT:-none}"

# Ensure we run as root (or with sudo privileges) since loop mounting is required
if [ "$EUID" -ne 0 ]; then
    log_warn "This script requires superuser privileges to mount images. Re-running with sudo..."
    exec sudo GSI_URL="$GSI_URL" \
         OUTPUT_FS="$OUTPUT_FS" \
         REMOVE_VNDK_V28="${REMOVE_VNDK_V28:-false}" \
         REMOVE_VNDK_V29="${REMOVE_VNDK_V29:-false}" \
         REMOVE_VNDK_V30="${REMOVE_VNDK_V30:-false}" \
         REMOVE_VNDK_V31="${REMOVE_VNDK_V31:-false}" \
         REMOVE_VNDK_V32="${REMOVE_VNDK_V32:-false}" \
         REMOVE_VNDK_V33="${REMOVE_VNDK_V33:-false}" \
         REMOVE_WALLPAPERS="${REMOVE_WALLPAPERS:-false}" \
         REMOVE_SOUNDS="${REMOVE_SOUNDS:-false}" \
         REMOVE_FONTS="${REMOVE_FONTS:-false}" \
         REMOVE_LIVE_WALLPAPERS="${REMOVE_LIVE_WALLPAPERS:-false}" \
         REMOVE_PIXEL_THEMES="${REMOVE_PIXEL_THEMES:-false}" \
         COMPRESS_OUTPUT="$COMPRESS_OUTPUT" \
         bash "$0" "$@"
fi

# Create workspace directories
mkdir -p "$WORKSPACE_DIR"
rm -rf "$SYS_DIR"
mkdir -p "$SYS_DIR"

log_info "Calculating GSI naming..."
# Check if any VNDKs were removed
REMOVE_VNDK="false"
for ver in 28 29 30 31 32 33; do
    var_name="REMOVE_VNDK_V${ver}"
    if [ "${!var_name:-false}" = "true" ]; then
        REMOVE_VNDK="true"
        break
    fi
done

# Check if any debloating was requested
DEBLOAT="false"
DEBLOAT_VARS=(
    "REMOVE_WALLPAPERS"
    "REMOVE_SOUNDS"
    "REMOVE_FONTS"
    "REMOVE_LIVE_WALLPAPERS"
    "REMOVE_PIXEL_THEMES"
)
for var in "${DEBLOAT_VARS[@]}"; do
    if [ "${!var:-false}" = "true" ]; then
        DEBLOAT="true"
        break
    fi
done

# Extract original filename from URL (stripping query parameters)
ORIG_FILENAME=$(basename "$GSI_URL")
ORIG_FILENAME="${ORIG_FILENAME%%\?*}"

# Strip known compression/archive and image extensions to find the core base name
TEMP_NAME="$ORIG_FILENAME"
while true; do
    case "$TEMP_NAME" in
        *.xz) TEMP_NAME="${TEMP_NAME%.xz}" ;;
        *.7z) TEMP_NAME="${TEMP_NAME%.7z}" ;;
        *.zip) TEMP_NAME="${TEMP_NAME%.zip}" ;;
        *.gz) TEMP_NAME="${TEMP_NAME%.gz}" ;;
        *.tar) TEMP_NAME="${TEMP_NAME%.tar}" ;;
        *.tgz) TEMP_NAME="${TEMP_NAME%.tgz}" ;;
        *.img) TEMP_NAME="${TEMP_NAME%.img}" ;;
        *) break ;;
    esac
done
BASE_GSI_NAME="$TEMP_NAME"

# Detect and extract date suffix at the end (e.g. -20260711, _20260711, -2026-07-11)
DATE_SUFFIX=""
if [[ "$BASE_GSI_NAME" =~ ([-_][0-9]{8}|[-_][0-9]{4}[-_][0-9]{2}[-_][0-9]{2})$ ]]; then
    DATE_SUFFIX="${BASH_REMATCH[1]}"
    BASE_GSI_NAME="${BASE_GSI_NAME%"$DATE_SUFFIX"}"
fi

# Strip trailing tags like EROFS, EXT4, DEBLOATED, VNDK (case-insensitive)
shopt -s nocasematch
while true; do
    if [[ "$BASE_GSI_NAME" =~ ([-_]erofs|[-_]ext4|[-_]debloated|[-_]vndk)$ ]]; then
        SUFFIX="${BASH_REMATCH[1]}"
        BASE_GSI_NAME="${BASE_GSI_NAME%"$SUFFIX"}"
    else
        break
    fi
done
shopt -u nocasematch

# Build tags
TAGS=""
if [ "$REMOVE_VNDK" = "true" ]; then
    TAGS="${TAGS}-VNDK"
fi
if [ "$DEBLOAT" = "true" ]; then
    TAGS="${TAGS}-DEBLOATED"
fi

# Upper case target filesystem tag
FS_TYPE=$(echo "$OUTPUT_FS" | tr '[:lower:]' '[:upper:]')
TAGS="${TAGS}-${FS_TYPE}"

# Re-assemble the new raw image name
OUT_IMG_NAME="${BASE_GSI_NAME}${TAGS}${DATE_SUFFIX}.img"

# Compression extension
COMPRESS_EXT=""
if [ "$COMPRESS_OUTPUT" = "xz" ]; then
    COMPRESS_EXT=".xz"
elif [ "$COMPRESS_OUTPUT" = "7z" ]; then
    COMPRESS_EXT=".7z"
fi

OUT_FILE_NAME="${OUT_IMG_NAME}${COMPRESS_EXT}"
OUT_FILE="$WORKSPACE_DIR/$OUT_FILE_NAME"
CHECKSUM_FILE="${OUT_FILE}.sha256"

log_info "Original Filename: $ORIG_FILENAME"
log_info "Target Image Filename: $OUT_IMG_NAME"
log_info "Output Filename: $OUT_FILE_NAME"

# Download setup
# Match on the URL with any query string stripped: SourceForge URLs carry
# signed parameters after '?' (e.g. ".../GSI.7z?viasf=1&fid=...") which would
# otherwise hide the real extension and make us mis-handle the archive as a
# raw .img (a copy of the archive itself) instead of extracting it.
DOWNLOADED_FILE="$WORKSPACE_DIR/gsi_archive"
URL_BASE="${GSI_URL%%\?*}"
if [[ "$URL_BASE" =~ \.xz$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.xz"
elif [[ "$URL_BASE" =~ \.7z$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.7z"
elif [[ "$URL_BASE" =~ \.zip$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.zip"
elif [[ "$URL_BASE" =~ \.tar\.gz$ || "$URL_BASE" =~ \.tgz$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.tar.gz"
else
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.img"
fi

# 1. Download GSI
log_header "Download GSI"
run_cmd bash "$SCRIPT_DIR/download.sh" "$GSI_URL" "$DOWNLOADED_FILE"
DOWNLOAD_SIZE=$(du -sh "$DOWNLOADED_FILE" | cut -f1)
log_step_success "Download complete ($DOWNLOAD_SIZE)"

# 2. Extract GSI
log_header "Extract GSI"
run_cmd bash "$SCRIPT_DIR/extract.sh" "$DOWNLOADED_FILE" "$EXTRACT_DIR" "$INPUT_IMAGE"
log_step_success "Extraction complete"

# Detect Filesystem of original RAW image
log_header "Detect filesystem type"

# Prints "<fs_type> <byte_offset>" on success, where byte_offset is where the
# filesystem actually starts inside the raw image (some GSIs pad the start of
# the partition image). Detection is done by matching superblock magic bytes
# directly, so it does not depend on blkid/file(1) version quirks.
# When nothing is recognized, diagnostics are printed to stderr and 1 is returned.
detect_fs_type() {
    local img="$1"
    local candidate m1 m2
    local -a offsets=(0 512 4096 65536)

    for candidate in "${offsets[@]}"; do
        # EROFS: superblock magic at filesystem offset 1024
        #   v1 = 0xE0F5E1E2, v2 = 0xE2E1F5E0 (little-endian on disk)
        m1=$(od -An -tx1 -N4 -j $((candidate + 1024)) "$img" 2>/dev/null | tr -d ' \n')
        # ext2/3/4: magic 0xEF53 at superblock offset 1024 + 56
        m2=$(od -An -tx1 -N2 -j $((candidate + 1080)) "$img" 2>/dev/null | tr -d ' \n')
        case "$m1" in
            e2e1f5e0|e0f5e1e2)
                echo "erofs $candidate"
                return 0
                ;;
        esac
        if [ "$m2" = "53ef" ]; then
            echo "ext4 $candidate"
            return 0
        fi
    done

    # Fallback: let blkid do a full probe (handles exotic superblock positions)
    local blk_type
    blk_type=$(blkid -p -s TYPE -o value "$img" 2>/dev/null || true)
    case "$blk_type" in
        ext2|ext3|ext4) echo "ext4 0"; return 0 ;;
        erofs)          echo "erofs 0"; return 0 ;;
    esac

    # Fallback: file(1) string matching
    local file_info
    file_info=$(file -b "$img" 2>/dev/null || true)
    if echo "$file_info" | grep -qi "erofs"; then
        echo "erofs 0"; return 0
    elif echo "$file_info" | grep -qiE "ext[234]"; then
        echo "ext4 0"; return 0
    fi

    # Not a recognized raw filesystem image - dump diagnostics to help debugging
    {
        echo "File: $img"
        echo "Size: $(stat -c '%s bytes' "$img" 2>/dev/null || echo 'unreadable')"
        echo "file(1): $file_info"
        echo "blkid -p: $(blkid -p "$img" 2>&1 || true)"
        echo "first16: $(od -An -tx1 -N16 "$img" 2>/dev/null | tr -d ' \n')"
        for candidate in "${offsets[@]}"; do
            echo "offset $candidate: erofs_magic=$(od -An -tx1 -N4 -j $((candidate + 1024)) "$img" 2>/dev/null | tr -d ' \n') ext_magic=$(od -An -tx1 -N2 -j $((candidate + 1080)) "$img" 2>/dev/null | tr -d ' \n')"
        done
    } >&2
    return 1
}

DETECT_RESULT=""
if ! DETECT_RESULT=$(detect_fs_type "$INPUT_IMAGE"); then
    log_error "Could not detect filesystem of GSI image $INPUT_IMAGE (must be ext4 or erofs). See diagnostics above."
    exit 1
fi
ORIGINAL_FS="${DETECT_RESULT%% *}"
FS_OFFSET="${DETECT_RESULT##* }"
FS_UPPER=$(echo "$ORIGINAL_FS" | tr '[:lower:]' '[:upper:]')
if [ "$FS_OFFSET" -gt 0 ]; then
    log_step_success "$FS_UPPER detected (filesystem starts at byte offset $FS_OFFSET)"
else
    log_step_success "$FS_UPPER detected"
fi

# 3. Mount GSI partition and copy contents
log_header "Mount GSI partition"
MNT_SRC=$(mktemp -d -p "$PWD" mnt_src.XXXXXX)
MOUNT_OPTS="loop,ro"
if [ "$FS_OFFSET" -gt 0 ]; then
    MOUNT_OPTS="loop,ro,offset=$FS_OFFSET"
fi
if ! mount -o "$MOUNT_OPTS" "$INPUT_IMAGE" "$MNT_SRC" >/dev/null 2>&1; then
    log_error "Failed to mount GSI image read-only."
    rm -rf "$MNT_SRC"
    exit 1
fi
cp -a "$MNT_SRC/." "$SYS_DIR/"
umount "$MNT_SRC"
rm -rf "$MNT_SRC"
log_step_success "Mount and copy complete"

# 4. Remove selected VNDKs
if [ "$REMOVE_VNDK" = "true" ]; then
    log_header "Remove selected VNDKs"
    run_cmd bash "$SCRIPT_DIR/remove_vndk.sh" "$SYS_DIR"
    echo -e "${TICK} Removed:"
    for ver in 28 29 30 31 32 33; do
        var_name="REMOVE_VNDK_V${ver}"
        if [ "${!var_name:-false}" = "true" ]; then
            echo "  - v$ver"
        fi
    done
fi

# 5. Apply debloating
if [ "$DEBLOAT" = "true" ]; then
    log_header "Debloat system partition"
    run_cmd bash "$SCRIPT_DIR/debloat.sh" "$SYS_DIR"
    echo -e "${TICK} Removed:"
    if [ "${REMOVE_WALLPAPERS:-false}" = "true" ]; then echo "  - Static Wallpapers"; fi
    if [ "${REMOVE_SOUNDS:-false}" = "true" ]; then echo "  - System Sounds"; fi
    if [ "${REMOVE_FONTS:-false}" = "true" ]; then echo "  - Non-essential Fonts"; fi
    if [ "${REMOVE_LIVE_WALLPAPERS:-false}" = "true" ]; then echo "  - Live Wallpapers"; fi
    if [ "${REMOVE_PIXEL_THEMES:-false}" = "true" ]; then echo "  - Pixel Theme Overlays"; fi
fi

# 6. Build GSI image
log_header "Build GSI image (${FS_TYPE})"
case "$OUTPUT_FS" in
    ext4)
        run_cmd bash "$SCRIPT_DIR/build_ext4.sh" "$SYS_DIR" "$OUTPUT_IMAGE"
        ;;
    erofs)
        run_cmd bash "$SCRIPT_DIR/build_erofs.sh" "$SYS_DIR" "$OUTPUT_IMAGE"
        ;;
    *)
        log_error "Unsupported output filesystem: $OUTPUT_FS"
        exit 1
        ;;
esac
log_step_success "Build complete"

# 7. Compress GSI image
if [ "$COMPRESS_OUTPUT" != "none" ]; then
    COMP_UPPER=$(echo "$COMPRESS_OUTPUT" | tr '[:lower:]' '[:upper:]')
    log_header "Compress GSI image"
    run_cmd bash "$SCRIPT_DIR/compress.sh" "$OUTPUT_IMAGE" "$COMPRESS_OUTPUT" "$OUT_FILE"
    log_step_success "Compression complete"
else
    run_cmd bash "$SCRIPT_DIR/compress.sh" "$OUTPUT_IMAGE" "$COMPRESS_OUTPUT" "$OUT_FILE"
fi

# 8. Generate SHA256 checksum
log_header "Generate SHA256"
run_cmd bash "$SCRIPT_DIR/checksum.sh" "$OUT_FILE" "$CHECKSUM_FILE"
log_step_success "Done"

# 9. Clean up intermediate workspace files
rm -f "$DOWNLOADED_FILE"
rm -f "$INPUT_IMAGE"
rm -f "$OUTPUT_IMAGE"
rm -rf "$EXTRACT_DIR"
rm -rf "$SYS_DIR"

echo ""
