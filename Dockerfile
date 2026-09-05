# One container, one job: wake up each day, collect, and never lose a day.
#
# The image is disposable. The data is not — data/ and db/ MUST be bind
# mounted from the host, or rebuilding this image erases the time series.
FROM python:3.12-slim

# sqlite3 CLI: backup snapshots, freshness checks, publish.
# rsync + openssh-client: scripts/backup.sh to an off-site host.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sqlite3 rsync openssh-client ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Run as a real user, not root. chmod 444 on an archive is worthless if the
# process that writes it can ignore permission bits -- root can. Set UID/GID
# to match the host account that owns the bind mounts (1000 = ubuntu).
ARG UID=1000
ARG GID=1000
RUN groupadd -g "${GID}" modelpass 2>/dev/null || true \
 && useradd -u "${UID}" -g "${GID}" -m -s /bin/bash modelpass 2>/dev/null || true

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY db/schema.sql       db/schema.sql
COPY src/                src/
COPY scripts/            scripts/
COPY config/             config/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh scripts/*.sh \
 && mkdir -p /app/data /app/state /app/logs /app/docs \
 && chown -R "${UID}:${GID}" /app

USER modelpass

# Everything the container must keep is a mount point, never image state.
# /app/db is NOT a mount point: it holds schema.sql from the image.
# The database itself lives under /app/state (see MODELPASS_DB).
VOLUME ["/app/data", "/app/state", "/app/logs", "/app/docs"]

ENV PYTHONUNBUFFERED=1 \
    RUN_AT_UTC=03:00 \
    TOP=1000 \
    MODELPASS_DB=/app/state/modelpass.db

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
