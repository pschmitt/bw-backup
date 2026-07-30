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

## 10. Downstream (nixos-config.git, rofl-10) — done
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
32. [x] `services.bw-sync.collections` enabled. The Bergmann-Schmitt org
        and both collections created directly via `rbw` (using an
        already-configured local account pointed at the same Vaultwarden
        instance) before flipping the config on: `rbw org create`, then
        `rbw collection create` x2. Vaultwarden auto-creates its own
        "Default Collection" alongside a brand-new org -- harmless, the
        sync only ever targets the exact-name "default" collection
        created here, never that one. Org membership for anyone besides
        destAccount (e.g. Anika) still needs `rbw org invite`/`rbw org
        confirm` by hand -- not something this module automates, and not
        done yet.
33. [x] `bw-backup.git` pushed to `github:pschmitt/bw-backup` (`main`),
        `nixos-config.git`'s `bw-backup` and top-level `rbw` flake inputs
        both re-pointed at `github:` (off the temporary `path:` override)
        and kept in sync across several follow-up fixes (see §11).

## 11. Validation — done, against the real production accounts on rofl-10
34. [x] `bw-backup.service` and `bw-sync.service` both run for real (not a
        throwaway account — `rbw register`/2FA meant a disposable test
        account wouldn't have caught the real bugs anyway). Three actual
        bugs surfaced across successive redeploys, each fixed, verified,
        and redeployed in turn:
        - `mkRegisterCheck` referenced `${backupCfg.package}/bin/rbw` --
          the bw-backup/bw-sync derivation itself, which only wraps `rbw`
          onto its own PATH via `wrapProgram`, never installs an `rbw`
          binary into its own `bin/`. Fixed to reference `pkgs.rbw`
          directly.
        - `rbw` in turn couldn't launch its own `rbw-agent` (plain PATH
          lookup, nothing set up in that standalone script's env). Fixed
          by exporting both `PATH` and `$RBW_AGENT` in the generated
          register scripts.
        - The personal bitwarden.com account has Authenticator-based TOTP
          2FA, which the old api-key-based `bw` CLI login never needed to
          clear. Added `BW_TOTP_SECRET`/`SRC_BW_TOTP_SECRET`/
          `DEST_BW_TOTP_SECRET` (optional, base32, via `oathtool`) to
          `lib.sh`'s `rbw_prepare_account` -- see §4/§5/§6 above.
35. [x] Both jobs completed cleanly end-to-end once those were fixed:
        `bw-backup` produced a real 27.4MB encrypted export and pruned
        correctly; `bw-sync` (personal mode, `--purge-dest`) purged the
        destination's personal vault and mirrored 2211 entries / 41
        attachments in 1m42s with zero errors -- notably faster and
        cleaner than the old bw-cli/bw.py pipeline it replaced (~6
        minutes, several failed attachment uploads logged the night
        before). Also fed back upstream: `rbw`'s own TODO.md previously
        flagged `mirror`'s whole-vault `--purge-dest` path as never
        live-verified (sandbox had no pinentry/TTY) -- this run is that
        verification, recorded there too.

36. [x] `services.bw-sync.collections` live-verified too, once §10 item 32
        turned it on. Two more real bugs surfaced and were fixed:
        - `envList` didn't quote `Environment=` values -- systemd
          word-splits unquoted values on whitespace, so
          `DEST_BW_COLLECTIONS`/`DEST_BW_ORG` (both containing spaces in
          the real org/collection names) got silently truncated at the
          first space, logged only as "Invalid environment assignment,
          ignoring: hat"/"ihr"/etc with no indication *which* variable
          was affected. Fixed by wrapping every value in double quotes.
        - `services.bw-sync.collections.workDir`'s tmpfiles rule didn't
          get applied by the switch that first enabled it (an unrelated
          "root user activation failed: Connection is closed" hiccup
          during that same switch likely interrupted it), so the first
          run failed with `Failed to set up mount namespacing: ...: No
          such file or directory`. Fixed by hand this once
          (`install -d`); worth keeping an eye on whether this recurs on
          a clean switch, since if so the module should probably not
          rely solely on the automatic tmpfiles application here.

        Both collections (`default`, `Anika hat ihr Passwort vergessen`)
        then mirrored 2211 entries / 53 attachments each in ~1m20s,
        exercising the *scoped per-collection* `--purge-dest` path this
        TODO previously flagged as genuinely unverified -- it executed
        cleanly ("no entries currently in '<collection>' -- nothing to
        purge", since these were brand-new empty collections). A run
        that actually has existing entries to purge (e.g. the next
        scheduled sync, or removing/renaming a source entry before a
        manual trigger) still hasn't been observed, so treat the
        purge-with-existing-entries case as the one remaining unverified
        edge until that happens naturally.

## 12. Phase 4 correction: collections mode mirrored the whole vault into
      every configured collection, not just a same-named source collection

37. [x] Production feedback after §11 item 36: the source account's whole
        personal vault ended up inside `Anika hat ihr Passwort vergessen`,
        instead of only the entries that already lived in a source-side
        collection of that name. Root cause: `mirror_collections` always
        did a full-vault `--dest-collection NAME --purge-dest` mirror for
        *every* configured name, with no way to instead scope to a
        matching source collection.
38. [x] Corrected design (confirmed with real production values, kept
        generic here): some destination collections should be a full
        vault mirror (when no source-side collection of that name
        exists), others should be a scoped 1:1 mirror of an
        equally-named source collection. Decided automatically per name,
        not via separate config lists.
39. [x] `lib.sh`: added `rbw_find_collection_id` -- lookup-only (never
        creates, unlike `rbw_ensure_collection`/`rbw_ensure_org`), prints
        the id of an exact-name match or nothing.
40. [x] `bw-sync.sh`'s `mirror_collections`: for each configured
        destination collection name, after ensuring it exists at the
        destination, looks up a same-named collection on the *source*
        via `rbw_find_collection_id`.
        - match found: scoped mirror, `--collection <src-id>
          --dest-collection NAME`, no `--purge-dest` (rbw's own guard
          clause refuses combining `--purge-dest` with a source-side
          `--collection`/`--org-id` scope -- stale destination entries in
          a scoped collection are left in place rather than purged).
        - no match: unchanged full-vault mirror,
          `--dest-collection NAME --purge-dest` -- this is how a
          collection can hold a full copy of the source vault (e.g. a
          "personal vault" collection with no source-side counterpart)
          rather than a 1:1 copy of an equally-named source collection.
        The source account is only ever read here, never modified --
        every rename/purge/create in response to this correction targets
        the destination account exclusively.
41. [x] Downstream (nixos-config.git): updated `collections.org`/
        `collections.names` to the corrected real values, bumped the
        `bw-backup`/`rbw` flake inputs, redeployed to rofl-10
        (`systemctl restart nixos-upgrade.service` there), and ran
        `bw-sync-collections.service` for real. Two of the three
        collections mirrored correctly (full-vault mirror into the
        collection with no source-side counterpart; scoped 1:1 mirror of
        the source collection into its same-named destination
        collection); the third failed with `rbw mirror: multiple
        collections found for 'Default collection': ... use the
        collection ID instead` -- see item 42.
42. [x] Root cause of that failure: two *different* destination orgs each
        had a collection named "Default collection" -- the real one, and
        a leftover from earlier rbw-fork live-testing (a throwaway
        "rbw-tests" org with its own auto-created default collection).
        `rbw mirror --dest-collection NAME`'s name resolution had no way
        to scope by destination org, so it matched both and refused to
        guess. Per instruction, did *not* touch/delete the stale test
        org -- fixed this properly instead by adding `--dest-org` to
        `rbw mirror` upstream (rbw v2.13.6) and passing it
        (`$org_id`, already resolved via `rbw_ensure_org`) on both
        `rbw mirror` call sites in `mirror_collections`. This also fixes
        the bug class generically, not just for this one collision.

        Also found and fixed while wiring this up: `bw-backup.git`
        commits its own `flake.lock` with an independent `rbw` pin,
        which had drifted stale (predating even the org-rename feature)
        -- so bumping `bw-backup`'s input in nixos-config.git alone
        wasn't enough, the *actual running binary* still lacked
        `--dest-org` until `bw-backup.git`'s own lock was bumped too.
        Fixed structurally by adding `bw-backup.inputs.rbw.follows =
        "rbw"` in nixos-config.git's flake.nix, so the two can never
        diverge again (confirmed via the resulting flake.lock: both
        collapse to the same node/rev now).

        **Re-verified end-to-end for real** after bumping both inputs,
        redeploying to rofl-10, and re-running
        `bw-sync-collections.service`: all three collections mirrored
        cleanly in one pass (`Private vault` purged 2212 stale entries
        from the earlier failed attempt and re-copied 2211 fresh;
        `Anika hat ihr Passwort vergessen` updated its existing 175;
        `Default collection` created its 28 with no ambiguity error this
        time), service exited 0 / `Result=success`. The first attempt in
        this run also hit a transient `rbw login: ... api request
        returned error: 500` from bitwarden.com on the source account --
        unrelated to this fix, resolved on a plain retry.
