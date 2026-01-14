# ==============================================================================
# Hytale Server Docker Image
# ==============================================================================
# Runs a Hytale game server with automatic updates via hytale-downloader.
# 
# SECURITY: No credentials are stored in this image. Provide authentication
# tokens at runtime via a mounted .hytale-downloader-credentials.json file.
# 
# NOTE: Uses Debian instead of Alpine because Hytale's QUIC library requires glibc
# ==============================================================================

FROM eclipse-temurin:25-jdk

LABEL maintainer="Dealer Node <administration@dealernode.app>"
LABEL description="Hytale Game Server"
LABEL version="1.0.0"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd -r hytale && useradd -r -g hytale hytale

# Create server directory
WORKDIR /server

# Download hytale-downloader CLI with automatic platform detection
ARG TARGETOS
ARG TARGETARCH

RUN curl -fsSL -o hytale-downloader.zip "https://downloader.hytale.com/hytale-downloader.zip" && \
    unzip hytale-downloader.zip && \
    if [ "${TARGETOS:-linux}" = "windows" ]; then \
        mv hytale-downloader-windows-amd64.exe hytale-downloader.exe; \
        rm -f hytale-downloader-linux-amd64; \
    else \
        mv hytale-downloader-linux-amd64 hytale-downloader; \
        chmod +x hytale-downloader; \
        rm -f hytale-downloader-windows-amd64.exe; \
    fi && \
    rm -f hytale-downloader.zip QUICKSTART.md 2>/dev/null || true

# Create directories for persistent data
# Note: server-files is included so Docker volumes mount with correct ownership
RUN mkdir -p /server/universe /server/mods /server/config /server/.aot-cache /server/server-files && \
    chown -R hytale:hytale /server

# Copy entrypoint script
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Expose UDP port for QUIC protocol
EXPOSE 5520/udp

# Default environment variables
# Note: SERVER_PASSWORD and AUTH_MODE are set in entrypoint.sh to avoid
# false-positive security warnings from Hadolint (SecretsUsedInArgOrEnv)
ENV SERVER_NAME="Hytale Server - (Dealer Node)"
ENV MAX_PLAYERS=10
ENV MEMORY_MB=4096
ENV VIEW_DISTANCE=10
ENV UPDATE_MODE=auto
ENV ENABLE_AOT=true
ENV SKIP_UPDATE_CHECK=false

# Health check - verify server process is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "HytaleServer.jar" || exit 1

# Run as non-root user
USER hytale

ENTRYPOINT ["/entrypoint.sh"]

