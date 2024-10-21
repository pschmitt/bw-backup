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

## How do I decrypt my backup?

```shell
gpg --batch --yes --passphrase "mySecret1234" --decrypt \
  --output decrypted.tar.gz \
  data/bw-export-xxx.tar.gz.gpg
```

There's also a wrapper script for that: [decrypt.sh](decrypt.sh)
