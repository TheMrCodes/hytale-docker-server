# AGENTS.md - AI Coding Agent Guidelines

This document provides guidelines for AI coding agents working in this repository.

## Project Overview

A Docker-based Hytale game server with automated OAuth authentication, auto-updates,
and Discord webhook notifications. The codebase is primarily Bash scripts and Docker
configuration files.

## Technology Stack

| Technology       | Purpose                                    |
|------------------|--------------------------------------------|
| Bash             | Primary scripting language (entrypoint.sh) |
| Docker           | Container platform                         |
| Docker Compose   | Service orchestration                      |
| Java 25 (Temurin)| Hytale server runtime                      |
| jq               | JSON processing in shell scripts           |
| curl             | HTTP requests for OAuth and downloads      |

## Build & Run Commands

```bash
# Build and start (interactive - for first-time auth)
docker compose up --build

# Build and start (detached - requires Discord webhook or existing credentials)
docker compose up --build -d

# Rebuild after code changes
docker compose down && docker compose up --build

# View logs
docker compose logs --tail=100
docker compose logs -f  # Follow mode

# Stop server
docker compose down

# Full reset (removes all data volumes)
docker compose down -v

# Check container status
docker compose ps

# Execute command in running container
docker compose exec hytale-server <command>
```

## Linting & Validation

No automated linting is configured. When modifying files, use these tools locally:

```bash
# Bash scripts - use ShellCheck
shellcheck entrypoint.sh

# Dockerfile - use Hadolint
hadolint Dockerfile

# YAML files - use yamllint
yamllint docker-compose.yml

# Validate shell script syntax
bash -n entrypoint.sh
```

## Code Style Guidelines

### File Headers

All files must start with a block comment header:

```bash
# ==============================================================================
# File Title
# ==============================================================================
# Brief description of the file's purpose.
# ==============================================================================
```

### Section Separators

Use this pattern to separate major sections within files:

```bash
# ------------------------------------------------------------------------------
# Section Name
# ------------------------------------------------------------------------------
```

### Bash Scripting Conventions

| Element           | Convention              | Example                          |
|-------------------|-------------------------|----------------------------------|
| Functions         | snake_case              | `log_info`, `validate_integer`   |
| Constants/Config  | SCREAMING_SNAKE_CASE    | `SERVER_NAME`, `CREDENTIALS_FILE`|
| Local variables   | snake_case              | `local access_token`             |
| Quoting           | Double quotes for vars  | `"$variable"`, `"${array[@]}"`   |
| Literal strings   | Single quotes           | `'literal string'`               |

### Function Structure

```bash
function_name() {
    local param1="$1"
    local param2="$2"

    # Validate inputs early
    if [ -z "$param1" ]; then
        log_error "param1 is required"
        return 1
    fi

    # Main logic here
    log_info "Processing $param1"
}
```

### Error Handling

- Always use `set -e` at the start of scripts
- Use explicit error checks for critical operations
- Use the logging functions: `log_info`, `log_warn`, `log_error`
- Return non-zero exit codes on failure
- Validate inputs at function entry

```bash
if ! some_command; then
    log_error "some_command failed: $?"
    return 1
fi
```

### Dockerfile Conventions

- Use multi-line RUN with `&& \` for chaining
- Clean up package manager caches in the same layer
- Always run as non-root user in production
- Use explicit `COPY --chmod=` for scripts
- Add descriptive comments for each section

### Docker Compose Conventions

- Use descriptive volume names with project prefix (`hytale-`)
- Add inline comments explaining purpose of each setting
- Group related settings together (build, ports, volumes, resources)
- Use env_file for environment configuration

## Security Guidelines

1. **Never commit credentials** - All credential files are in `.gitignore`
2. **Use bind mounts for secrets** - Mount credentials at runtime, not build time
3. **Set restrictive permissions** - Use `chmod 600` for credential files
4. **Run as non-root** - Container runs as `hytale` user (UID 999)
5. **Validate all inputs** - Check environment variables before use
6. **Don't log secrets** - Never log tokens or passwords

## Environment Variables

All configuration is done via environment variables in `.env`:

- Copy `.env.example` to `.env` for local development
- Document all variables in `.env.example` with comments
- Provide sensible defaults in `entrypoint.sh`
- Validate required variables early in startup

## Git Conventions

- **Commit style**: Conventional commits (`feat:`, `fix:`, `docs:`, etc.)
- **Branch**: `main` is the primary branch
- **Never commit**: `.env`, `*credentials*.json`, downloaded binaries

## File Structure

```
├── .dockerignore          # Docker build exclusions
├── .env                   # Local config (gitignored)
├── .env.example           # Documented config template
├── .gitignore             # Git exclusions
├── AGENTS.md              # This file
├── Dockerfile             # Container image definition
├── README.md              # Project documentation
├── docker-compose.yml     # Service orchestration
└── entrypoint.sh          # Main container entrypoint
```

## Common Tasks

### Adding a new environment variable

1. Add default in `entrypoint.sh` configuration section
2. Add validation if required
3. Document in `.env.example` with description
4. Update README.md if user-facing

### Modifying OAuth flow

The OAuth device flow is in `entrypoint.sh`:
- `perform_device_auth()` - Initiates device code flow
- `create_game_session()` - Exchanges OAuth token for game session
- `refresh_and_create_session()` - Refreshes expired tokens
- `send_discord_notification()` - Sends webhook notifications

### Testing changes

1. Delete credentials to force re-auth: `rm .hytale-server-credentials.json`
2. Rebuild: `docker compose down && docker compose up --build`
3. Check logs: `docker compose logs --tail=50`
4. Verify server starts: Look for "Hytale Server Booted!" in logs
