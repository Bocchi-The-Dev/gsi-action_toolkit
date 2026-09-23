# GSI Builder

A GitHub Actions workflow to customize Android Treble Generic System Images (GSIs) directly in the cloud.

## Features

- Download a GSI from a direct URL
- Convert EXT4 ↔ EROFS
- Remove selected VNDK versions
- Optional debloating
- Preserve the original ROM filename
- Generate SHA256 checksum
- Upload artifacts automatically
- Upload a mirror of the image + checksum to [GoFile](https://gofile.io)

## Requirements

- GitHub Actions
- Direct download link to the GSI

## Usage

1. Fork this repo
2. Open the Actions tab in your repository.
3. Select "GSI Builder" from the workflow list.
4. Click "Run workflow".
5. Enter the GSI download URL and configure the build settings.
6. Click "Run workflow" to start the build.
7. Download the generated system image and checksum file from the workflow artifacts.

## Workflow Options

- **GSI URL**: Direct link to the source GSI image or compressed archive.
- **Output filesystem**: Select either ext4 (read-write) or erofs (read-only) for the output GSI partition.
- **Remove VNDK versions (v28 to v33)**: Select VNDK versions to remove from the system image to free up space.
- **Remove wallpapers**: Remove pre-installed wallpapers from the GSI.
- **Remove sounds**: Delete system alarms, notifications, ringtones, and user interface sounds.
- **Remove fonts**: Remove non-essential Noto fonts while keeping standard system fonts.
- **Remove live wallpapers**: Strip live wallpapers packages and pickers.
- **Remove pixel themes**: Remove Pixel-specific theme overlays.
- **Compress output**: Select compression format (none, xz, or 7z) for the generated GSI artifact.

## Output

Example output files:

Axion-2.7_GSI_treble_arm64-ab-GAPPS-EROFS-20260711.img.xz

Axion-2.7_GSI_treble_arm64-ab-GAPPS-EROFS-20260711.img.xz.sha256

## GoFile mirror

After the build, the workflow uploads the image and its checksum to [GoFile](https://gofile.io) and prints the download links in the job summary.

- **No setup required**: without a token, the workflow creates a temporary guest account and uploads there.
- **Persistent mirrors (recommended)**: add a GoFile account token as a repository secret named `GOFILE_TOKEN` (Settings → Secrets and variables → Actions → New repository secret). Uploads then go to your account, so files aren't deleted by GoFile's guest-expiry policy.
- If GoFile is unreachable the build still succeeds — the GitHub artifact upload already ran, and the mirror step is non-blocking (`continue-on-error`).

## License

This project is licensed under the MIT License.
