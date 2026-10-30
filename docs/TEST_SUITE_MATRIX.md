# TEST_SUITE_MATRIX — BPI-R4 Knots Appliance

**Authority:** REQUIREMENTS T1–T3, TECH_SPEC §13  
**Updated:** 2026-09-16  
**Rule:** Tests look for bugs; storage/sync use **real** devices/data when exercising those paths. Never wipe a live IBD disk unless the operator explicitly intends it.

---

## How to run

| Target | Command | Notes |
|--------|---------|-------|
| Host guards + script smoke | `make test-host` | No board required |
| Loop wipe (retired) | `make test-wipe-loop` | Asserts wipe script absent (**S7**) |
| On-device smoke | `make test-device SERIAL=/dev/ttyUSB0` | Read-only / negative; does **not** wipe M.2 |
| Full documented set | `make test` | `test-host` then optional device if `SERIAL` set |
| **IUE / Setup + TLS OS** | `make test-iue` | Host: all Setup scenarios + cert install sims; device if serial present |
| **Laptop web UAT** | `~/Documents/knots-uat/run` (install: `make uat-web-install LAPTOP=user@laptop`) | Full web regression; waits for reset/upgrades; **docs/UAT_WEB.md** |
| Zone isolation / stress | `make test-zone-security` | LAN (+ WAN/Wi‑Fi/DMZ via env); **T5**/**NF10** — `docs/SECURITY_ZONE_TEST.md` |

---

## Matrix

| Test ID | Req | Layer | Type | Script / check | Pass criteria |
|---------|-----|-------|------|----------------|---------------|
| T-LAN-1 | R*, N1 | P1 | integration | device smoke | Host `192.168.1.254`; DHCP pool `.100–.200` |
| T-UI-1 | N2, R13 | P1 | integration | device `test-ui.sh` | LuCI `:8080` login works (no 500); overview reachable |
| T-UI-2 | U1, U2, N9 | P3 | integration | device `test-ui.sh` | `https://…/` is Knots Node Status (not LuCI) |
| T-UI-NAV | U3, U1b, U7a, U8, U9 | P3 / Phase 2 | unit+device | `test-ui-nav.sh` / `test-ui.sh` | Top nav; theme; no Storage; Phase 2 no Wallet/External/Lightning/Privacy; wallet-switch warn; named-location `proxy_pass` has no URI (F172) |
| T-UI-STORAGE-HIDDEN | U8, D4 | P3/P5 | device | `test-ui.sh` | Primary nav has no Storage item |
| T-UI-U7A-SWITCH | U7a, B18 | P3 | unit+device | `test-ui-nav.sh` / `test-ui.sh` | Wallet warn + `WALLET_ACK` / `wallet_present` present |
| T-UI-LUCI-ENTRY | U3 | P3 | integration | device `test-ui.sh` | `:8080/` chooser has **Back to Node Status** before login |
| T-FW-1 | N6, N10 | P3 | integration | device smoke | WAN DNAT 8333 present; WAN mgmt ports rejected in UCI |
| T-FW-2 | N8 | P3 | integration | device smoke | No open LAN→DMZ forward for arbitrary ports |
| T-SEC-ZONE | T5, NF10, N2, N6, N8, N12 | Phase 2 retail | stress | `tests/security/*` + `docs/SECURITY_ZONE_TEST.md` | LAN/Wi‑Fi/WAN/DMZ probes; DMZ↛LAN; WAN mgmt closed; `make test-zone-security` |
| T-STO-1 | S1–S3 | P1 | integration | prepare path / AS_BUILT | Empty disk prepares; second boot mount-only |
| T-STO-2 | B13, S1 | P2 | negative | status/LED | Missing/unmounted M.2 → Knots not started; LED **error** |
| T-STO-3a | S7, U8, D4 | P5 | negative | `tests/host/test-wipe-guards.sh` | Wipe tools/UI/API **absent**; CLI wipe refuses |
| T-STO-3b | S7 | P5 | negative | `tests/host/test-wipe-guards.sh` | (merged into T-STO-3a — no sealed-wipe path) |
| T-STO-3c | S7 | P5 | unit | `tests/host/test-wipe-loop.sh` | Skip/assert wipe retired |
| T-STO-3d | S7 | P5 | unit | `tests/host/test-wipe-loop.sh` | Skip/assert wipe retired |
| T-STO-4 | S4 | P2 | integration | device smoke | `/mnt/bitcoin` mounted; datadir present while IBD |
| T-NODE-1 | B1–B5 | P2 | integration | device smoke | LXC `21.21.21.21`; peers ≥ 1 when WAN up |
| T-VER-1 | R1a | P1 | integration | device smoke | `product_version` matches `{openwrt}.{core}.{build}` |
| T-NODE-IMPL-PERSIST | B15, R1a | Phase 2 | unit | `test-node-impl-persist.sh` | Dual persist helpers; build number; refuse unmounted writes |
| T-LED-1 | N4 | P3 | integration | device smoke | `led-status` → `syncing`/`synced`/`booting`/`error`; sysfs trigger set |
| T-ID-1 | S6 | P4 | unit | `tests/host/test-identity-regen.sh` | Factory marker → removes peers/cookie; flag set; second run no-op |
| T-FAC-1 | D3, S5 | P4 | smoke | `tests/host/test-factory-scripts.sh` | capture/flash scripts `--help`/confirm gates |
| T-FAC-2 | R5a, DOC3a | Phase 2 | sim | `tests/host/test-install-emmc-sim.sh` | eMMC productionise state machine vs pty-simulated U-Boot: happy path, F28 guard, SD-inserted guard |
| T-RST-1 | N3, S7 | P3 | negative | `tests/host/test-factory-reset-guards.sh` | Missing `--confirm RESET` → refuse; `--wipe-storage` refused (retired) |
| T-RST-2 | N3, U17 | P3 | unit | `tests/host/test-factory-reset-guards.sh` | Clears Setup markers; `rc.button/reset` → `factory-reset` (WPS/KEY_RESTART; no `jffs2reset`) |
| T-RST-UI | N3, U17, U15 | Phase 2 | unit | `tests/host/test-settings-factory-reset-ui.sh` | Settings → `/reset.html` + progress copy + IUE Welcome (`step=0`); `expected_seconds` 650 (F175); F201 unique FR/UPG marker vars + `setsid` worker |
| T-SET-START-REINDEX | U18, B24 | Phase 2 | unit | `tests/host/test-settings-node-start.sh` | ReIndex checkbox; dropdown hidden until checked; default chainstate; distinct warnings; `reindex_kind=full` uses `bitcoind_ctl_reindex`; Start disabled/refused unless node is stopped (`already_running`); ReIndex grey + **Reindex in progress** when `reindex_running`; F204 `cgi_setsid` on conf_save/stop/start/Node set; Settings JS `pollNodeUntil` |
| T-WAIT-UX | U13, U17, N3, N13 | Phase 2 | unit | `tests/host/test-wait-handoff-ux.sh` | Keep-settings → HTTPS Node Status only after `/api/status`; `-n` / factory reset → HTTP Setup `step=0`; no cert-wall bounce; no 15s early finish |
| T-UPG-UI | U13, NF9 | Phase 2 | unit | `tests/host/test-settings-upgrade-ui.sh` | Four wait bars; F175 holdMs (`-n` Updating 450s, keep 90s); `UPG_SEC` 300/630 |
| T-IUE-FLOW | U17, U19, R7, R10a, R13 | Phase 2 | unit | `tests/host/test-iue-flow.sh` | Step order 0–9; factory AP `rnode`/`knotsnode21`; LAN/Wi‑Fi staged until Finish cutover |
| T-IUE-TLS-OS | N13, U17 | Phase 2 | unit+sim | `tests/host/test-iue-tls-os.sh` | Real CA; mobileconfig DER; OS detect/CTA for Win/mac/iOS/Android/Linux; install helpers with fake sudo; nginx Disposition |
| T-IUE-TLS-SCRIPTS | N13 | Phase 2 | unit | `tests/host/test-tls-install-scripts.sh` | Script syntax; chmod gate; bad CA reject; Linux Firefox HTTPS reopen (`after_tls=1`); Windows PS1 ASCII + no `$(…):port` (PS 5.1) |
| T-IUE-DEVICE | U17, N13, R11, U1 | Phase 2 | device | `tests/device/test-iue.sh` | Live `/api/setup`; TLS downloads; HTTP→HTTPS redirects; factory password / short wifi negatives |
| T-IUE-CLIENT | U17, N13, R7, R10a | Phase 2 | device | `tests/device/test-iue-client.sh` | Laptop via router SSH: mDNS, HTTP IUE, real CA install, Quick/Guided, USB serial must not re-enumerate |
| T-UAT-WEB | U1–U3, U7–U19, N3, N13, R14, B15, B22, B23 | Phase 2 | device UAT | `tests/device/uat-web.py` + `uat_wizard.py` (laptop `~/Documents/knots-uat/run`) | IUE Playwright (Welcome/Security/after_tls Choice F208/Quick/Guided — not `/api/setup` POST); Guided LAN DHCP start 110 + SSID `ClientGuided`; bitcoin.conf `maxconnections`; browser Node Status/Node/Settings + LuCI return; waits through reboot, keep-upgrade, factory reset, reset-upgrade; `~/Documents/*sysupgrade.itb`; `results/last-run.log` + `last-run.json` + `results/shots/`; no serial / no M.2 wipe |
| T-HTTP-HTTPS | U1, U1a, N13, B6 | Phase 2 | unit | `tests/host/test-http-https-redirect.sh` | nginx 80→443 + 8080→8443; CA allowlist; uhttpd HTTPS-only; F204 `:80` `/api/node` proxy |
| T-NGX-T | U1, N13 | Phase 2 | unit | `tests/host/test-nginx-conf.sh` | Real `nginx -t` on overlay; lint F129/F170/F172; negative F172 fixture must fail `-t`; UI JS `node --check` |

---

## Explicit non-goals for automated CI

- Full multi-week IBD to tip (manual / soak).
- Flashing production M.2 images in CI (operator factory station).
- Wiping the lab board’s live IBD during routine `make test-device`.

---

## Mapping to REQUIREMENTS

| REQUIREMENTS | Covered by |
|--------------|------------|
| T1 real data | T-STO-4, T-NODE-1 on board |
| T2 (if listed) | AS_BUILT live proofs |
| T3 storage negatives | T-STO-3a–d, T-STO-1/2 |
| N4 LED | T-LED-1 |
| S5–S6 / D3 | T-FAC-1, T-ID-1 + factory README |
| S7 / U8 / D4 | T-STO-3a–d (wipe absent), storage UI/API gone |
