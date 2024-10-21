# hadolint ignore=DL3007
FROM alpine:latest AS bw
# hadolint ignore=DL4006,SC2035,DL3018
RUN apk add --no-cache curl jq unzip && \
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
    apt-get install -y --no-install-recommends bash jq gnupg2 && \
    rm -rf /var/lib/apt/list/*

# NOTE bw is dynamically linked!
COPY --from=bw /bw /usr/local/bin/bw
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

VOLUME ["/data"]
ENV BW_URL=https://bitwarden.com \
    BW_CLIENTID="user.xxxx" \
    BW_CLIENTSECRET="changeme" \
    BW_PASSWORD="changeme" \
    ENCRYPTION_PASSPHRASE= \
    KEEP=10
