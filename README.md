# bw-backup

## Usage

```shell
podman run -it --rm \
  -v /tmp/data:/data \
  -e BW_CLIENTID=user.xxxx \
  -e BW_CLIENTSECRET=xxxx \
  -e BW_PASSWORD=xxxx \
  -e ENCRYPTION_PASSPHRASE=mySecret1234 \
  -e KEEP=10 \
  -e CRON="0 23 * * *" \
  ghcr.io/pschmitt/bw-backup:latest
```

`ENCRIPTION_PASSPHRASE` is optional. If set the backups will be encrypted with
the given passphrase.

`KEEP` is optional. If set the script will keep the last `KEEP` backups.

`CRON` is optional. If set the script will run the backup script periodically.

`HEALTHCHECK_URL` is optional. If set the script will ping Healthchecks.io (or
compatible endpoints) when the backup starts, completes successfully, or fails.

### Sync between two vaults

Run the container with the `sync` command to copy all items (and attachments) from
one Bitwarden/Vaultwarden instance to another:

```shell
podman run -it --rm \
  -e SRC_BW_CLIENTID=src.xxxx \
  -e SRC_BW_CLIENTSECRET=xxxx \
  -e SRC_BW_PASSWORD=xxxx \
  -e DEST_BW_CLIENTID=dest.xxxx \
  -e DEST_BW_CLIENTSECRET=xxxx \
  -e DEST_BW_PASSWORD=xxxx \
  -e DEST_BW_EMAIL=you@example.com \
  ghcr.io/pschmitt/bw-backup:latest sync
```

Optional:
- `DEST_BW_PURGE_VAULT` if set to `1` will delete all items in the destination vault
before importing.
- `DOWNLOAD_PARALLELISM` controls parallel attachment downloads (default: 10).
- `HEALTHCHECK_URL` works here too; sync will ping start/fail/success.

## How do I decrypt my backup?

```shell
gpg --batch --yes --passphrase "mySecret1234" --decrypt \
  --output decrypted.tar.gz \
  data/bw-export-xxx.tar.gz.gpg
```

There's also a wrapper script for that: [decrypt.sh](decrypt.sh)
