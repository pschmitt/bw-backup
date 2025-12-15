# hadolint ignore=DL3007
FROM alpine:latest AS bw
# hadolint ignore=DL4006,SC2035,DL3018
RUN apk add --no-cache ca-certificates curl jq unzip && \
    BW_URL=$(curl -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/bitwarden/clients/releases | \
      jq -er ' \
        [.[] | select(.name | test("CLI"))][0] | \
        .assets[] | select(.name | test("^bw-linux.*.zip")) | \
        .browser_download_url \
      ') && \
    curl -fsSL "$BW_URL" | funzip - > bw && \
    chmod +x ./bw

# hadolint ignore=DL3007
FROM ubuntu:latest
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash ca-certificates cron curl gnupg2 jq python3 && \
    rm -rf /var/lib/apt/lists/* /etc/cron.*/*

# NOTE bw is dynamically linked!
COPY --from=bw /bw /usr/local/bin/bw
COPY bw-backup.sh /usr/local/bin/bw-backup
COPY bw-sync.sh /usr/local/bin/bw-sync
COPY bw.py /usr/local/bin/bw.py
COPY entrypoint.sh /entrypoint.sh
COPY lib.sh /usr/local/bin/lib.sh

ENTRYPOINT ["/entrypoint.sh"]

VOLUME ["/data"]
ENV BW_URL=https://bitwarden.com \
    BW_BACKUP_DIR=/data \
    BW_CLIENTID="user.xxxx" \
    BW_CLIENTSECRET="changeme" \
    BW_PASSWORD="changeme" \
    SOURCE_BW_URL= \
    SOURCE_BW_CLIENTID= \
    SOURCE_BW_CLIENTSECRET= \
    SOURCE_BW_PASSWORD= \
    DEST_BW_URL= \
    DEST_BW_CLIENTID= \
    DEST_BW_CLIENTSECRET= \
    DEST_BW_PASSWORD= \
    DEST_BW_EMAIL= \
    DEST_BW_PURGE_VAULT= \
    ENCRYPTION_PASSPHRASE= \
    BW_BACKUP_RETENTION=30 \
    CRON=
