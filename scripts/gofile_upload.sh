#!/usr/bin/env bash
set -euo pipefail

# Upload files to GoFile (gofile.io) and print a public mirror link per file.
#
# Usage: gofile_upload.sh <file> [<file> ...]
#
# Optional environment:
#   GOFILE_TOKEN   GoFile account token. If unset, a guest account is created
#                  on the fly (files expire sooner than account uploads).
#   LINKS_FILE     Path to write the download links (one per line, optional).
#
# In GitHub Actions this also writes step outputs `gofile_image` /
# `gofile_checksum` and appends the links to the job summary.

API="https://api.gofile.io"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <file> [<file> ...]" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# --- 1. Acquire an upload token -------------------------------------------
token="${GOFILE_TOKEN:-}"
if [ -n "$token" ]; then
    echo "GoFile: using provided GOFILE_TOKEN"
else
    echo "GoFile: no GOFILE_TOKEN set, creating a guest account"
    acc="$(curl -fsS -X POST "${API}/accounts")"
    token="$(echo "${acc}" | jq -r '.data.token // empty')"
    if [ -z "$token" ]; then
        echo "error: could not create GoFile guest account: ${acc}" >&2
        exit 1
    fi
fi

# --- 2. Pick an upload server ----------------------------------------------
server="$(curl -fsS "${API}/servers" | jq -r '.data.servers[0].name // empty')"
if [ -z "$server" ]; then
    echo "error: could not determine a GoFile upload server" >&2
    exit 1
fi
upload_api="https://${server}.gofile.io"
echo "GoFile: upload server selected: ${server}"

# --- 3. Upload each file ----------------------------------------------------
links_file="${LINKS_FILE:-}"
: > "${links_file:-/dev/null}" 2>/dev/null || true

n=0
declare -A page_link
for file in "$@"; do
    [ -f "$file" ] || { echo "error: file not found: ${file}" >&2; exit 1; }
    name="$(basename "${file}")"
    n=$((n + 1))
    echo "GoFile: uploading ${name} ($(du -h "${file}" | cut -f1)) ..."

    resp="$(curl -fsS \
        -H "Authorization: Bearer ${token}" \
        -F "file=@${file}" \
        "${upload_api}/contents/uploadfile")"

    status="$(echo "${resp}" | jq -r '.status // empty')"
    link="$(echo "${resp}"   | jq -r '.data.downloadPage // empty')"
    if [ "${status}" != "ok" ] || [ -z "${link}" ]; then
        echo "error: GoFile upload failed for ${name}: ${resp}" >&2
        exit 1
    fi

    echo "GoFile: ✓ ${name} -> ${link}"
    if [ -n "${links_file}" ]; then
        echo "${link}" >> "${links_file}"
    fi
    page_link["${name}"]="${link}"
done

# --- 4. GitHub Actions integration ------------------------------------------
first="$(basename "${1}")"
second="$(basename "${2:-}")"

{
    echo "gofile_image=${page_link["${first}"]}"
    [ -n "${second}" ] && [ "${first}" != "${second}" ] && \
        echo "gofile_checksum=${page_link["${second}"]}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## GoFile mirror"
        echo
        echo "Download links (mirror of the build artifacts):"
        echo
        echo "| File | Link |"
        echo "|---|---|"
        for f in "$@"; do
            name="$(basename "${f}")"
            echo "| ${name} | [gofile.io/d/$(echo "${page_link[$name]}" | sed 's#.*/d/##')](${page_link[$name]}) |"
        done
        echo
        if [ -z "${GOFILE_TOKEN:-}" ]; then
            echo "> ⚠️ Uploaded as guest. GoFile removes guest uploads after a period of inactivity — set a \`GOFILE_TOKEN\` secret for persistent mirrors."
        fi
    } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "GoFile: done"