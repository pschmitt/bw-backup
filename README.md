# bw-backup

## Usage

```shell
podman run -it --rm \
  -v /tmp/data:/data \
  -e BW_CLIENTID=user.xxxx \
  -e BW_CLIENTSECRET=xxxx \
  -e BW_PASSWORD=xxxx \
  ghcr.io/pschmitt/bw-backup:latest
```
