# bw-backup

Backup and sync helpers for Bitwarden/Vaultwarden, built on top of
[rbw](https://github.com/pschmitt/rbw) (specifically
[pschmitt/rbw](https://github.com/pschmitt/rbw), a fork with multi-account
support, native vault-to-vault mirroring, and non-interactive
login/unlock/export/import/purge). `rbw` does the heavy lifting (auth,
export/import, attachments, org/collection management); these scripts are
thin wrappers adding backup rotation, healthchecks, and idempotent org/
collection creation on top.

The backup archive format changed from the old `bw`-CLI-based version of
this repo: it's now whatever `rbw export` produces (its own JSON, optionally
gpg-encrypted), not the old `bw export` + `bw list items` + attachments
tarball. There's no compatibility shim -- old archives from before this
rewrite must be restored with the old `bw`-CLI-based tooling.

Every account used here (for backup, or as sync source/destination) must
already be configured in `rbw`'s `config.json` (name/email/base_url) --
these scripts only ever supply the master password (and, once, a personal
API key for `rbw register`) at runtime. The NixOS module (see below)
renders `config.json` for you; for plain Docker usage, `entrypoint.sh`
renders it from env vars on every start.

*Note on bitwarden.com*: the official server requires a one-time `rbw
register` (personal API key) per account before scripted login works (bot
detection). Both scripts run this automatically before login, but it's a
no-op unless you supply that account's `*_REGISTER_CLIENT_ID`/
`*_REGISTER_CLIENT_SECRET` env vars (see below) -- get the key from
[bitwarden.com](https://bitwarden.com/help/article/personal-api-key/).

## Backup

```shell
podman run -it --rm \
  -v /tmp/data:/data \
  -e ACCOUNT_EMAIL=me@example.com \
  -e BW_PASSWORD=xxxx \
  -e ENCRYPTION_PASSPHRASE=mySecret1234 \
  -e BW_BACKUP_RETENTION=30 \
  -e CRON="0 23 * * *" \
  ghcr.io/pschmitt/bw-backup:latest
```

- `ACCOUNT` (optional, default: `backup`): the rbw account name.
- `ACCOUNT_EMAIL`: the account's email address (used to render `config.json`).
- `ACCOUNT_BASE_URL` (optional): the account's server URL, omit for the
  official bitwarden.com.
- `BW_PASSWORD`: the account's master password.
- `BW_TOTP_SECRET` (optional): the account's TOTP secret (base32, the same
  one an authenticator app would use), if it has TOTP-based 2FA enabled.
  A fresh code is generated per login/unlock via `oathtool`.
- `BW_BACKUP_REGISTER_CLIENT_ID`/`BW_BACKUP_REGISTER_CLIENT_SECRET`
  (optional): personal API key, used once to run `rbw register`
  non-interactively against bitwarden.com.
- `BW_BACKUP_ATTACHMENTS` (optional, default: `1`): set to `0` to skip
  downloading/embedding attachment contents (faster, smaller, but
  attachments won't be restorable from that backup).
- `ENCRYPTION_PASSPHRASE` (optional): if set, backups are gpg-encrypted
  (`rbw export --encrypt`) with this passphrase.
- `BW_BACKUP_RETENTION` (optional, default: `30`): how many backups to
  keep. Set to `0` to disable rotation. `KEEP` is deprecated; use this
  instead.
- `CRON` (optional): if set, runs the backup periodically on this schedule
  instead of once.
- `HEALTHCHECK_URL` (optional): pings Healthchecks.io (or a compatible
  endpoint) when the backup starts, completes successfully, or fails.
- `BW_BACKUP_DIR` (optional, default: `/data`): where backups are written.
  Mount your volume accordingly.

## Sync between two vaults

Run the container with the `sync` command to mirror one Bitwarden/
Vaultwarden account's vault into another (via `rbw mirror` -- entries and
attachments, no temp files):

```shell
podman run -it --rm \
  -e SRC_ACCOUNT_EMAIL=you@example.com \
  -e SRC_BW_PASSWORD=xxxx \
  -e DEST_ACCOUNT_EMAIL=you@vaultwarden.example \
  -e DEST_ACCOUNT_BASE_URL=https://vault.example.com \
  -e DEST_BW_PASSWORD=xxxx \
  ghcr.io/pschmitt/bw-backup:latest sync
```

- `SRC_ACCOUNT`/`DEST_ACCOUNT` (optional, default: `source`/`destination`):
  the rbw account names.
- `SRC_ACCOUNT_EMAIL`/`DEST_ACCOUNT_EMAIL`, `SRC_ACCOUNT_BASE_URL`/
  `DEST_ACCOUNT_BASE_URL`: connection metadata for `config.json`.
- `SRC_BW_PASSWORD`/`DEST_BW_PASSWORD`: the two accounts' master passwords.
- `SRC_BW_TOTP_SECRET`/`DEST_BW_TOTP_SECRET` (optional): TOTP secrets for
  whichever account(s) have TOTP-based 2FA enabled, same as `BW_TOTP_SECRET`
  above.
- `SRC_REGISTER_CLIENT_ID`/`SRC_REGISTER_CLIENT_SECRET`,
  `DEST_REGISTER_CLIENT_ID`/`DEST_REGISTER_CLIENT_SECRET` (optional):
  personal API keys for `rbw register`, same as above.
- `BW_SYNC_MODE` (optional, default: `personal`):
  - `personal`: mirror the entire source vault into the destination
    account's personal vault, 1:1.
  - `collections`: mirror the entire source vault into one or more
    destination organization collections (see below), each getting its
    own independent full mirror.
- `DEST_BW_PURGE_VAULT` (optional, `personal` mode only): if set to `1`,
  wipes the destination's personal vault before importing (server-side
  purge, same as `rbw purge-vault`). Entries in an org collection are
  never touched by this.
- `DEST_BW_ORG`/`DEST_BW_COLLECTIONS` (required in `collections` mode):
  the destination organization name and a comma-separated list of
  collection names to mirror into, e.g.
  `DEST_BW_COLLECTIONS="default,Some Other Collection"`. The org and any
  missing collections are created automatically.
- `BW_SYNC_ATTACHMENTS` (optional, default: `1`): set to `0` to skip
  attachments.
- `BW_SYNC_OVERWRITE` (optional, default: `1`): set to `0` to leave
  existing destination entries untouched instead of overwriting them.
- `HEALTHCHECK_URL` works here too; sync pings start/fail/success.

## NixOS module

`flake.nix` exports `nixosModules.default`, providing
`services.bw-backup` and `services.bw-sync` (with a nested
`services.bw-sync.collections` for the org/collection job). Both render
their own `rbw` `config.json` declaratively and run the same `rbw
register` automation described above from `environmentFiles`-supplied env
vars. See `nix/module.nix` for the full option list.

## How do I decrypt my backup?

`rbw export --encrypt` wraps the JSON export in a tar.gz before
gpg-encrypting it, so decrypting yields a tar.gz (extract it to get at the
JSON):

```shell
gpg --batch --yes --passphrase "mySecret1234" --decrypt \
  --output decrypted.tar.gz \
  data/bw-export-xxx.tar.gz.gpg
tar xzf decrypted.tar.gz
```

There's also a wrapper script for the decrypt step: [decrypt.sh](decrypt.sh)
