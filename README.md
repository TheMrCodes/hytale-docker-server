# Hytale Docker Server

A fully automated Docker container for hosting Hytale game servers with OAuth authentication, automatic updates, and Discord notifications.

## Features

- **Automated OAuth Authentication** - Device flow authentication with token persistence and auto-refresh
- **Discord Webhook Integration** - Receive authentication links via Discord when running headless
- **Automatic Updates** - Configurable update modes (auto/always/never) with version tracking
- **Persistent Storage** - Separate volumes for server files, world data, mods, and config
- **Java AOT Caching** - Faster server startup after initial run
- **Non-root Container** - Runs as unprivileged user for security
- **Multi-platform** - Supports `linux/amd64` and `linux/arm64`
- **Configurable** - All settings via environment variables

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- A Hytale account with server access
- Existing `hytale-downloader` credentials file (from initial setup)

### Option A: Use Pre-built Image (Recommended)

```bash
# Create project directory
mkdir hytale-server && cd hytale-server

# Download configuration files
curl -O https://raw.githubusercontent.com/TheMrCodes/hytale-docker-server/main/.env.example
curl -O https://raw.githubusercontent.com/TheMrCodes/hytale-docker-server/main/docker-compose.ghcr.yml
mv docker-compose.ghcr.yml docker-compose.yml

# Configure
cp .env.example .env
# Edit .env with your settings

# Add your credentials
cp ~/.hytale-downloader-credentials.json .hytale-downloader-credentials.json

# Start server
docker compose up
```

Or create your own `docker-compose.yml`:

```yaml
services:
  hytale-server:
    image: ghcr.io/themrcodes/hytale-docker-server:latest
    ports:
      - "5520:5520/udp"
    env_file:
      - .env
    volumes:
      - ./.hytale-downloader-credentials.json:/server/.hytale-downloader-credentials.json:ro
      - hytale-server-files:/server/server-files
      - hytale-mods:/server/mods
      - hytale-config:/server/config
    stdin_open: true
    tty: true

volumes:
  hytale-server-files:
  hytale-mods:
  hytale-config:
```

### Option B: Build from Source

#### 1. Clone the Repository

```bash
git clone https://github.com/TheMrCodes/hytale-docker-server.git
cd hytale-docker-server
```

#### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your settings
```

#### 3. Add Downloader Credentials

Copy your existing credentials file to the project directory:

```bash
cp ~/.hytale-downloader-credentials.json .hytale-downloader-credentials.json
```

Or run `hytale-downloader` once to generate credentials.

#### 4. Start the Server (First Time)

Run interactively to complete server authentication:

```bash
docker compose up --build
```

Follow the on-screen instructions to authenticate:
1. Visit the displayed URL
2. Enter the verification code
3. Authorize the server

#### 5. Run in Background

After initial authentication, run detached:

```bash
docker compose up -d
```

## Configuration

All configuration is done via the `.env` file:

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | `My Hytale Server` | Server display name |
| `SERVER_PASSWORD` | *(empty)* | Server password (optional) |
| `MAX_PLAYERS` | `10` | Maximum concurrent players |
| `VIEW_DISTANCE` | `10` | Chunk view distance |
| `MEMORY_MB` | `4096` | Java heap size in MB |
| `AUTH_MODE` | `authenticated` | `authenticated` or `open` |
| `UPDATE_MODE` | `auto` | `auto`, `always`, or `never` |
| `ENABLE_AOT` | `true` | Enable Java AOT caching |
| `DISCORD_WEBHOOK_URL` | *(empty)* | Discord webhook for auth notifications |

## Discord Webhook Setup

To receive authentication links when running headless:

1. Go to your Discord server settings
2. Navigate to **Integrations** → **Webhooks**
3. Create a new webhook and copy the URL
4. Add to your `.env`:
   ```
   DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
   ```

When authentication is required, you'll receive a Discord message with:
- The verification code
- A direct link to authenticate

## Update Modes

| Mode | Behavior |
|------|----------|
| `auto` | Check for updates on startup, download if newer version available |
| `always` | Force download server files on every startup |
| `never` | Never download, use existing files only |

## Mods

Server mods are stored in the `hytale-mods` volume, mounted at `/server/mods` inside the container.

### Installing Mods

1. Copy mod files into the running container:
   ```bash
   docker cp ./my-mod.jar hytale-server:/server/mods/
   ```

2. Or use a bind mount in `docker-compose.yml` for easier management:
   ```yaml
   volumes:
     - ./mods:/server/mods
   ```

3. Restart the server to load mods:
   ```bash
   docker compose restart
   ```

## World Management

World data is stored inside the `hytale-server-files` volume at `/server/server-files/universe/worlds/`.

### World Structure

```
/server/server-files/universe/
├── memories.json
├── players/          # Player data
└── worlds/
    └── default/      # Default world
        ├── chunks/
        ├── config.json
        └── resources/
```

### Importing a World

To import an existing world (replacing the default world):

1. **Stop the server:**
   ```bash
   docker compose down
   ```

2. **Copy your world into the volume:**
   ```bash
   # Remove existing default world and copy new one
   docker run --rm \
     -v hytale_hytale-server-files:/data \
     -v "$(pwd)/YourWorldFolder:/src:ro" \
     alpine sh -c "rm -rf /data/universe/worlds/default && cp -r /src /data/universe/worlds/default"
   ```

3. **Start the server:**
   ```bash
   docker compose up -d
   ```

### Backing Up World Data

```bash
# Create a backup of all world data
docker run --rm \
  -v hytale_hytale-server-files:/data:ro \
  -v "$(pwd):/backup" \
  alpine tar -czf /backup/universe-backup.tar.gz -C /data universe
```

### Restoring from Backup

```bash
docker compose down
docker run --rm \
  -v hytale_hytale-server-files:/data \
  -v "$(pwd):/backup:ro" \
  alpine sh -c "rm -rf /data/universe && tar -xzf /backup/universe-backup.tar.gz -C /data"
docker compose up -d
```

## Docker Volumes

| Volume | Purpose |
|--------|---------|
| `hytale-server-files` | Server JAR, assets, and world data (~3.5GB) |
| `hytale-mods` | Server mods (place `.jar` or mod folders here) |
| `hytale-config` | Server configuration and auth credentials |

## Commands

```bash
# Start server (interactive)
docker compose up

# Start server (background)
docker compose up -d

# View logs
docker compose logs -f

# Stop server
docker compose down

# Rebuild after changes
docker compose down && docker compose up --build

# Full reset (removes all data)
docker compose down -v

# Check status
docker compose ps
```

## Authentication Flow

### First-time Setup

1. Server starts and checks for existing credentials
2. If no valid credentials, initiates OAuth device flow
3. Displays verification URL and code (also sent to Discord if configured)
4. User authorizes via browser
5. Server receives OAuth tokens and creates game session
6. Credentials saved to `.hytale-server-credentials.json`

### Subsequent Starts

1. Server loads saved credentials
2. Checks if session tokens are still valid
3. If expired, refreshes OAuth token and creates new game session
4. Server starts with valid authentication

### Token Lifecycle

| Token | Validity | Auto-refresh |
|-------|----------|--------------|
| OAuth Access Token | 1 hour | Yes |
| OAuth Refresh Token | 30 days | Yes (on use) |
| Game Session Token | 1 hour | Yes (by server) |

## Building from Source

```bash
# Clone repository
git clone https://github.com/TheMrCodes/hytale-docker-server.git
cd hytale-docker-server

# Copy and configure environment
cp .env.example .env

# Build image
docker compose build

# Run
docker compose up
```

## File Structure

```
├── .env.example           # Configuration template
├── .gitignore             # Git exclusions
├── AGENTS.md              # AI agent guidelines
├── Dockerfile             # Container build instructions
├── README.md              # This file
├── docker-compose.yml     # Container orchestration
└── entrypoint.sh          # Startup script
```

## Troubleshooting

### "Server authentication unavailable" error

Players see this when connecting if the server lacks valid tokens.

**Solution**: Re-run the server interactively to authenticate:
```bash
docker compose down
rm .hytale-server-credentials.json
docker compose up
```

### Server won't start in detached mode

The server needs initial authentication which requires user interaction.

**Solution**: Either:
- Run interactively first: `docker compose up` (without `-d`)
- Configure `DISCORD_WEBHOOK_URL` to receive auth links

### OAuth token expired

If the refresh token expires (after 30 days of no use), you'll need to re-authenticate.

**Solution**:
```bash
rm .hytale-server-credentials.json
docker compose up
```

### Permission denied errors

The container runs as a non-root user. Bind-mounted files need appropriate permissions.

**Solution**:
```bash
chmod 600 .hytale-*-credentials.json
```

## Security Notes

- Credentials are stored locally and never committed to git
- Container runs as unprivileged user (UID 999)
- OAuth tokens are automatically refreshed
- All sensitive files use restrictive permissions (600)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes following the guidelines in `AGENTS.md`
4. Submit a pull request

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Hytale](https://hytale.com) - The game
- [Eclipse Temurin](https://adoptium.net) - Java runtime
- [hytale-downloader](https://downloader.hytale.com) - Official server file downloader

---

## Disclaimer

**This is a hobby project** provided "as is" without warranty of any kind, express or implied. Use at your own risk. The authors are not responsible for any damages, data loss, or issues arising from the use of this software.

This project was mostly **vibe coded** with AI assistance (even with professional oversight). While efforts have been made to ensure functionality and security, the code may contain bugs, inefficiencies, or unconventional patterns. Community contributions and improvements are welcome!

This project is not affiliated with, endorsed by, or associated with Hypixel Studios or Hytale.
