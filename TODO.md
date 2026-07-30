# TODO: port bw-backup/bw-sync onto rbw

Context: the pschmitt/rbw fork now natively does most of what these scripts
hand-rolled (`rbw export`/`rbw import`/`rbw purge-vault`/`rbw collection`/`rbw
org`, multi-account support via `--account`, non-interactive `--stdin`
login/unlock). Goal: replace the custom bw-cli/jq/gpg/bw.py logic with thin
wrappers around rbw. Backup archive format is allowed to change (confirmed by
Philipp — no need for byte compatibility with old `bw-export-*.tar.gz`).

**Major discovery mid-port**: rbw already has `rbw mirror --from A --to B
[--collection X] [--org-id Y] [--dest-collection Z] [--attachments]
[--overwrite] [--purge-dest] [-y] [--stdin]` — a single native command that
replaces the entire hand-rolled export|import|attachment-remap pipeline this
TODO originally planned. `bw-sync.sh` now just logs both accounts in/unlocks/
syncs them, then calls `rbw mirror` once (personal mode) or once per
collection (collections mode, with `--dest-collection NAME --purge-dest` for
a true per-collection full mirror — no password reproof needed for that
scoped-purge path). No temp files, no `bw.py`, no id-mapping.

Also discovered mid-port: `rbw register` (needed once per bitwarden.com
account to bypass bot detection) had no non-interactive path at all — added
`--stdin` support to the rbw fork itself (protocol/agent/CLI plumbing),
verified with `cargo build/test/clippy`+`cargo fmt --all` on the `rofl-13`
scratch host, committed locally to `rbw.git` (not pushed).

Decisions locked in:
- Build both sync jobs now: (1) 1:1 personal-vault mirror, (2) a
  destination-org mirror into one-or-more collections, each collection
  getting a full mirror (not a folder/tag split).
- Refactor the Docker image too, not just the Nix side.
- Automate the one-time `rbw register` (personal API key) step — done via
  `ExecStartPre` (Nix) / entrypoint.sh (Docker), both reading plain env vars
  from `environmentFiles`/`secrets.env` (no separate secret-file option
  machinery — config.json itself only ever holds non-secret name/email/
  base_url, so there was nothing secret left to route through the Nix
  store).

## 1. Flake plumbing — done
1. [x] Add `inputs.rbw.url = "github:pschmitt/rbw"` to `flake.nix`.
2. [x] Wire `rbw.overlays.default` into this flake's overlay/package set.
3. [x] Bump `flake.lock` accordingly.

## 2. Packages (`nix/bw-backup.nix`, `nix/bw-sync.nix`) — done
4. [x] Swap `bitwarden-cli` for `rbw` in both derivations' `makeBinPath`.
5. [x] Drop `python3` from `nix/bw-sync.nix` (`bw.py` deleted).
6. [x] Pruned to actual usage: `bw-backup` keeps `gnupg` (rbw shells out to
       system `gpg` for `--encrypt`) but no longer needs `gnutar`/`gzip`
       (rbw's own `tar`/`flate2` crates handle that in-process); `bw-sync`
       needs `jq` (org/collection id lookups in `lib.sh`) but no
       `gnupg`/`gawk`/`gnugrep`/`gnused`/`python3`. Both built successfully
       via `nix build .#bw-backup .#bw-sync` and smoke-tested.

## 3. NixOS module (`nix/module.nix`) — done
7. [x] Render `~<user>/.config/rbw/config.json` per service user via
       `systemd.tmpfiles.rules` (`d`/`L+`, pointing at a `pkgs.writeText`
       store path) — turned out to need no `_secret`/activation-script
       machinery at all, since config.json only holds non-secret
       name/email/base_url; the Nix store copy is fine as-is.
8. [x] Account `email`/`base_url`/`ssoId` are plain Nix options
       (`accountModule` submodule); master passwords and register API keys
       are plain env vars from `environmentFiles`, piped to `--stdin` at
       run time — never in config.json or a literal `Environment=`.
9. [x] `services.bw-backup.account` (name/email/baseUrl/ssoId); kept
       `backupPath`/`retention`/`schedule`/`monit`/`environmentFiles`.
10. [x] `services.bw-sync.sourceAccount`/`destAccount`; kept
        `purgeDestination`.
11. [x] `services.bw-sync.collections` (nested, reuses the parent's
        `sourceAccount`/`destAccount`): `enable`, `org`, `names` (list),
        `period`, `monit`, `workDir` — separate `workDir`/`LAST_SYNC` from
        the personal job so their freshness markers can't clobber each
        other. Generates a distinct `bw-sync-collections.service`+`.timer`,
        same `bw-sync` user/config.json as the personal job.
12. [x] `rbw register --stdin` automated via a generated `ExecStartPre`
        script per service, reading `BW_BACKUP_REGISTER_CLIENT_ID`/
        `_SECRET` (backup) or `SRC_`/`DEST_REGISTER_CLIENT_ID`/`_SECRET`
        (sync, both jobs) — no-ops when unset. Safe to run every start:
        rbw's own `db.needs_login()` guard makes it idempotent.
13. [x] Monit checks kept, plus a new one for the collections job
        (`bw-sync-collections`, own `LAST_SYNC` file).
14. [x] Assertions/tmpfiles/user creation updated (`ensureBackupUser`/
        `ensureSyncUser` now also gate on `collections.enable`); added
        assertion that `collections.names` isn't empty when enabled.

Verified end-to-end: built a full NixOS `system.build.toplevel` with
`services.bw-backup`, `services.bw-sync` (`purgeDestination = true`), and
`services.bw-sync.collections` (two collection names, one containing
spaces) all enabled — correct units/timers/tmpfiles/register-scripts/
config.json all confirmed by inspecting the build output directly.

## 4. `lib.sh` — done
15. [x] Dropped `download_attachments` entirely (`rbw`/`rbw mirror` handle
        attachments natively).
16. [x] Added `rbw_prepare_account` (login+unlock+sync, `--stdin`),
        `rbw_cleanup_account`, `rbw_ensure_org`, `rbw_ensure_collection`
        (idempotent, `--raw` JSON + `jq`).
17. [x] Kept `echo_info`/`echo_warning`/`echo_error`/`healthcheck_ping`
        unchanged.

## 5. `bw-backup.sh` — done
18. [x] `bw_export` now just logs the account in/unlocks/syncs it, then
        one `rbw --account "$ACCOUNT" export [--attachments] [--encrypt]
        --output "$dest"` call.
19. [x] `backup_rotate`, lockfile handling, healthcheck pings unchanged.
20. [x] `cleanup()` uses `rbw_cleanup_account` (`rbw lock`/`rbw purge`)
        instead of `bw logout`; no more scratch `BW_CONFIG_HOME` to remove
        (config.json is now a persistent, module-managed file).

## 6. `bw-sync.sh` — done, simpler than planned (see mirror discovery above)
21. [x] `mirror_personal`/`mirror_collections`, both just shelling out to
        `rbw mirror` after both accounts are logged in/unlocked/synced.
22. [x] `personal` mode: `DEST_BW_PURGE_VAULT=1` adds `--purge-dest --stdin`
        (whole-vault purge, master password piped in).
23. [x] `collections` mode: for each configured collection, ensures
        org+collection exist (`rbw_ensure_org`/`rbw_ensure_collection`),
        then `rbw mirror ... --dest-collection NAME --purge-dest` (scoped
        purge, no password needed) for a true full mirror per collection.
24. [x] `write_last_sync`/healthcheck ping/workdir cleanup kept, trimmed
        (no more export/attachments state on disk to clean up).

## 7. Delete — done
25. [x] `bw.py` deleted.

## 8. Docker — done
26. [x] `Dockerfile` now multi-stage-copies `rbw`/`rbw-agent` from
        `ghcr.io/pschmitt/rbw:latest` instead of building/fetching the
        official `bw` CLI; dropped the alpine/unzip build stage and
        `python3` from the runtime image.
27. [x] `entrypoint.sh` renders `~/.config/rbw/config.json` from env vars
        (`ACCOUNT_EMAIL`/`ACCOUNT_BASE_URL`, `SRC_`/`DEST_ACCOUNT_EMAIL`/
        `_BASE_URL`) before dispatching to bw-backup/bw-sync;
        `docker-compose.yaml` volume list dropped the `bw.py` mount;
        `run.sh` needed no changes (only forwards to compose services by
        name). Built the image and smoke-tested both `backup` and `sync`
        commands (fake creds, confirmed real `rbw`→bitwarden.com login
        attempts reach the server and are rejected as expected — i.e. the
        whole config.json→rbw→network path works end-to-end).

## 9. Docs — done
28. [x] `README.md` rewritten: new env vars, backup format change called
        out explicitly, both sync modes documented, register automation
        documented.
29. [x] `secrets.env.sample` updated for the new variable set.
30. [x] `decrypt.sh` needs no changes — confirmed from rbw's source
        (`build_export_tar_gz` + `gpg_symmetric_encrypt`, `--symmetric
        --cipher-algo AES256`) that `--encrypt` wraps the JSON as
        `vault.json` inside a tar.gz before a plain `gpg --symmetric`
        encrypt; plain `gpg --decrypt` (what decrypt.sh already does)
        reverses it regardless of cipher, yielding that tar.gz (extract it
        to get `vault.json`). README's decrypt section updated to mention
        the extra `tar xzf` step.

## 10. Downstream (nixos-config.git, rofl-10) — done, minus the collections job
31. [x] `services/backups/bitwarden.nix` updated against the new module
        shape (`account`/`sourceAccount`/`destAccount` submodules) with
        the real account emails/base URL filled in (via `SOPS_AGE_KEY`
        from `ssh-to-age` + `rbw get` against the user's own vault, per
        instruction). `hosts/rofl-10/secrets.sops.yaml`'s `bw-backup`/
        `bw-sync` entries rewritten in place (`sops set`, same underlying
        credential values, restructured/renamed keys for the new scripts
        -- `BW_CLIENTID`/`BW_CLIENTSECRET` -> `*_REGISTER_CLIENT_ID`/
        `*_REGISTER_CLIENT_SECRET`, dropped entirely for the destination
        account since Vaultwarden has no bot-detection/register step;
        `BW_URL`/`DEST_BW_URL` moved out of the secret into the plain
        `baseUrl` Nix option). Verified by evaluating the real
        `nixosConfigurations.rofl-10` (not just a synthetic test config)
        — `systemd.services.bw-backup`/`bw-sync` `serviceConfig` and
        `tmpfiles.rules` all render correctly against production data.
        `flake.nix`'s `bw-backup` input temporarily switched to the
        already-scaffolded `path:` override (local working tree) since
        nothing's been pushed yet — flip back to `github:pschmitt/
        bw-backup` once it has been (see §33).
32. [ ] `services.bw-sync.collections` still left commented out (real
        org/collection names intentionally not committed anywhere) until
        the destination org and any other member's Vaultwarden account
        membership in it actually exist — `rbw org invite`/`rbw org
        confirm` aren't something this module automates.
33. [ ] Re-point the `bw-backup` flake input back at `github:pschmitt/
        bw-backup` once it's actually pushed there (nothing in
        `bw-backup.git` has been committed yet, let alone pushed — only
        `rbw.git` has: `register --stdin` plus the `2.13.3` version bump,
        both pushed, tag `v2.13.3` pushed too, triggering the `release`/
        `docker` GH Actions workflows).

## 11. Validation — not started, do this before touching rofl-10's real cron/timers
34. [ ] Dry-run `bw-backup` against a throwaway/test bitwarden.com or
        Vaultwarden account (not the real personal vault) end-to-end,
        including `rbw register` if it's an official-server test account.
35. [ ] Dry-run `bw-sync` in both modes against disposable test
        accounts/org (create a scratch org + a scratch collection, not
        the real destination org) — `--purge-dest` (both the whole-vault and
        scoped-collection variants) is irreversible, and the scoped
        per-collection purge path in `rbw mirror` specifically has *not*
        been live-verified upstream yet (only unit/clippy-tested, per
        rbw's own TODO.md) — treat it as unverified until proven otherwise
        against a disposable collection.
