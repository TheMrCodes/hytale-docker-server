# Hytale Downloader — Quick Start Guide

## What is it?
A simple command-line tool to download Hytale server and asset files with OAuth2 authentication.

## Prerequisites
- A valid **Hytale account** with appropriate access

## Getting Started

Download the binary for your platform:
- `hytale-downloader-linux-amd64`
- `hytale-downloader-windows-amd64.exe`

Make it executable (Linux):
```bash
chmod +x hytale-downloader-linux-amd64
```

## Basic Usage

### Download the Latest Version
```bash
./hytale-downloader
```

**First-time setup:** You'll see a URL and authorization code — open the URL in a browser to log in. The tool will automatically detect when you've authenticated and start the download.

### Check Available Version
```bash
./hytale-downloader -print-version
```

### Download to a Specific Location
```bash
./hytale-downloader -download-path /path/to/game.zip
```

### Use a Different Patchline
```bash
./hytale-downloader -patchline pre-release
```

## Quick Reference

| Command | What it Does |
|---------|--------------|
| `./hytale-downloader` | Download latest release |
| `./hytale-downloader -print-version` | Show game version without downloading |
| `./hytale-downloader -version` | Show hytale-downloader version |
| `./hytale-downloader -check-update` | Check for hytale-downloader updates |
| `./hytale-downloader -download-path game.zip` | Download to specific file |
| `./hytale-downloader -patchline pre-release` | Download from pre-release channel |
| `./hytale-downloader -skip-update-check` | Skip the automatic update check |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Authentication error | Delete `.hytale-downloader-credentials.json` and re-run |
| Device code expired | Restart the tool to get a new authorization code |
| Checksum mismatch | Retry the download |
| 401 Unauthorized | Re-authenticate (delete credentials file) |
| 404 Not Found | Check patchline name & your access permissions |

## Important Notes
- **Credentials are saved** — you only need to log in once, although the credentials will be re-saved when they refresh so it is important to retain the updated credentials file if you're automating the usage

## Automatic Update Checks
The tool automatically checks for new versions of itself on startup. If a newer version is available, you'll see a message like:

```
A new version of hytale-downloader is available: 2025.01.31-abc1234 (current: 2025.01.15-def5678)
Download it from: https://downloader.hytale.com/hytale-downloader.zip
```

- Use `-check-update` to only check for updates without downloading game files
- Use `-skip-update-check` to disable this check (useful for automation)
- Use `-version` to see your current hytale-downloader version

## Tips
- **Files auto-validate** — SHA256 checksum verification happens automatically
- **Keep credentials secure** — add `.hytale-downloader-credentials.json` to `.gitignore` if you're using a Git repository
