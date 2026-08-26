# Repository instructions

Single instruction file for humans and AIs. **First contact is a router, not a dump.**

`lib/xray-manager-core.sh` is ~6800 lines / 230KB. Reading it whole is a context failure. `README.md` (~28KB) and `CHANGELOG.md` (~17KB) are user-facing, not a code map.

## First contact (mandatory)

1. You already have this file. Do **not** open:
   - `lib/xray-manager-core.sh` without a line range
   - `README.md` unless the task is user-facing docs
   - `CHANGELOG.md` unless the task is a release note
   - `tests/smoke-configs.sh` in full unless you are editing it
2. Route the task:
   ```bash
   bash scripts/maintainer-map.sh --ai "<task or error text>"
   ```
   If you cannot run commands, open `docs/ai/INDEX.md` and grep `docs/ai/core-symbols.tsv`.
3. Read **only** the returned `file:start-end` slices. Cap about 500 lines of Core per turn. Area `inbound-transport` is ~3000 lines — always narrow by protocol or function first.
4. After editing, run the tests listed by `--ai`, then `bash scripts/maintainer-map.sh --check`. If functions or MAP rows moved, regenerate with `bash scripts/maintainer-map.sh --write-index`.

## Source boundaries

- `xray-manager.sh`: installed launcher, version display, source selection, and manager self-update.
- `lib/xray-manager-core.sh`: interactive runtime and Xray configuration/service management.
- `install.sh`, `cloudflare-install.sh`, `offline-install.sh`: GitHub, Worker/R2, and offline bootstrap paths.
- `worker/`: authenticated delivery of the fixed private R2 objects.
- `scripts/select-xray-release.sh`, `scripts/select-geodata-release.sh`, `scripts/verify-xray-asset.sh`, and `publish-r2.yml`: delayed Xray/GeoData selection, upstream digest verification, and packaging policy.
- `tests/`: executable regression coverage. Core tests source the Core and override paths/service functions.
- `docs/ai/`: generated first-contact index. Do not hand-edit; regenerate with `--write-index`.

Keep Core as a single distributable file unless the same change also updates all installers, updater paths, offline packaging, checksums, and tests to install modules atomically.

## Non-negotiable invariants

- Test complete Xray configuration before replacing live files; back up before replacement and roll back if restart fails.
- Preserve `20_outbound_<tag>_tail.json`, the managed `30_routing.json`, routing-conflict refusal, and final-default-rule ordering.
- Preserve double confirmation, backup, and pre-switch validation for existing configuration migration.
- Never default to changing the host default route or publicly exposing unauthenticated SOCKS/HTTP listeners.
- Do not treat DNS64 as NAT64 and do not automatically enable WARP on IPv6-only hosts.
- Never persist or print `INSTALL_TOKEN`; keep the Worker secret out of source and ordinary Wrangler vars.
- Keep R2 publication on fixed overwrite-in-place object keys.
- WireGuard client private keys stay in root-only `${STATE_DIR}/wireguard/<tag>/` and mode `600` backups; never print the server private key or invent a client private key for a public-key-only peer.

## Required validation

- Bash changes: `bash -n` and ShellCheck for the changed scripts.
- Core configuration changes: add/update `tests/smoke-configs.sh` and run it with the pinned Xray binary/assets.
- Bootstrap/migration/update changes: run the matching standalone test under `tests/`.
- Worker changes: `cd worker && npm ci && npm run check`.
- Responsibility/path/function-cluster changes: `bash scripts/maintainer-map.sh --write-index && bash scripts/maintainer-map.sh --check`.
- Functional releases: update versions, `CHANGELOG.md`, user docs, and run `scripts/refresh-checksums.sh` as described in `CONTRIBUTING.md`.

Do not add load-time side effects to `lib/xray-manager-core.sh`; tests source it directly.
