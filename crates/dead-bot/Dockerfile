FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the Nix build
COPY target/release/dead-bot /usr/local/bin/dead-bot

# Create app directory
WORKDIR /app

# Run the bot
CMD ["dead-bot"]
