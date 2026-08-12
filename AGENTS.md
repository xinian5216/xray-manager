# Repository instructions

These instructions apply to the whole repository and are intended for human and AI maintainers.

## Start with the maintenance map

Before editing, run:

```bash
bash scripts/maintainer-map.sh "<symptom, feature, or error keyword>"
```

Use the returned implementation files, tests, and docs as the initial change scope. Read `docs/MAINTAINER_GUIDE.md` for architectural boundaries and safety invariants. Run `bash scripts/maintainer-map.sh --check` whenever paths or responsibilities change.

## Source boundaries

- `xray-manager.sh`: installed launcher, version display, source selection, and manager self-update.
- `lib/xray-manager-core.sh`: interactive runtime and Xray configuration/service management.
- `install.sh`, `cloudflare-install.sh`, `offline-install.sh`: GitHub, Worker/R2, and offline bootstrap paths.
- `worker/`: authenticated delivery of the fixed private R2 objects.
- `scripts/select-xray-release.sh`, `scripts/select-geodata-release.sh`, and `publish-r2.yml`: delayed Xray/GeoData selection and packaging policy.
- `tests/`: executable regression coverage. Core tests source the Core and override paths/service functions.

Keep Core as a single distributable file unless the same change also updates all installers, updater paths, offline packaging, checksums, and tests to install modules atomically.

## Non-negotiable invariants

- Test complete Xray configuration before replacing live files; back up before replacement and roll back if restart fails.
- Preserve `20_outbound_<tag>_tail.json`, the managed `30_routing.json`, routing-conflict refusal, and final-default-rule ordering.
- Preserve double confirmation, backup, and pre-switch validation for existing configuration migration.
- Never default to changing the host default route or publicly exposing unauthenticated SOCKS/HTTP listeners.
- Do not treat DNS64 as NAT64 and do not automatically enable WARP on IPv6-only hosts.
- Never persist or print `INSTALL_TOKEN`; keep the Worker secret out of source and ordinary Wrangler vars.
- Keep R2 publication on fixed overwrite-in-place object keys.

## Required validation

- Bash changes: `bash -n` and ShellCheck for the changed scripts.
- Core configuration changes: add/update `tests/smoke-configs.sh` and run it with the pinned Xray binary/assets.
- Bootstrap/migration/update changes: run the matching standalone test under `tests/`.
- Worker changes: `cd worker && npm ci && npm run check`.
- Responsibility/path changes: `bash scripts/maintainer-map.sh --check`.
- Functional releases: update versions, `CHANGELOG.md`, user docs, and run `scripts/refresh-checksums.sh` as described in `CONTRIBUTING.md`.

Do not add load-time side effects to `lib/xray-manager-core.sh`; tests source it directly.
