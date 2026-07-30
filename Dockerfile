# hadolint ignore=DL3007
FROM ghcr.io/pschmitt/rbw:latest AS rbw

# hadolint ignore=DL3007
FROM ubuntu:latest
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash ca-certificates cron curl gnupg2 jq oathtool && \
    rm -rf /var/lib/apt/lists/* /etc/cron.*/*

COPY --from=rbw /usr/bin/rbw /usr/local/bin/rbw
COPY --from=rbw /usr/bin/rbw-agent /usr/local/bin/rbw-agent
COPY bw-backup.sh /usr/local/bin/rbw-auto-backup
COPY bw-sync.sh /usr/local/bin/rbw-auto-sync
COPY entrypoint.sh /entrypoint.sh
COPY lib.sh /usr/local/bin/lib.sh

ENTRYPOINT ["/entrypoint.sh"]

VOLUME ["/data"]

# --- backup (single account) ---
ENV ACCOUNT=backup \
    ACCOUNT_EMAIL= \
    ACCOUNT_BASE_URL= \
    BW_PASSWORD="changeme" \
    BW_TOTP_SECRET= \
    BW_BACKUP_DIR=/data \
    BW_BACKUP_RETENTION=30 \
    ENCRYPTION_PASSPHRASE=

# --- sync (source + destination accounts) ---
ENV SRC_ACCOUNT=source \
    SRC_ACCOUNT_EMAIL= \
    SRC_ACCOUNT_BASE_URL= \
    SRC_BW_PASSWORD= \
    SRC_BW_TOTP_SECRET= \
    DEST_ACCOUNT=destination \
    DEST_ACCOUNT_EMAIL= \
    DEST_ACCOUNT_BASE_URL= \
    DEST_BW_PASSWORD= \
    DEST_BW_TOTP_SECRET= \
    BW_SYNC_MODE=personal \
    DEST_BW_PURGE_VAULT= \
    DEST_BW_ORG= \
    DEST_BW_COLLECTIONS=

ENV CRON=
