# BPI-R4 Bitcoin Knots Appliance v3.0 — Technical Specification

**Status:** Build-ready elaboration of `REQUIREMENTS.md`  
**Date:** 2026-08-07  
**Focus:** P1–P5 (router + Knots). P6–P7 reserved.

If this document conflicts with `REQUIREMENTS.md`, **REQUIREMENTS wins** — amend REQUIREMENTS first.

---

## 0. Document map

| Section | Contents |
|---------|----------|
| §1 | Architecture |
| §2 | Repo layout |
| §3 | Addressing, ports, DHCP |
| §4 | UCI network / firewall / DHCP |
| §5 | Storage (M.2) + first-boot |
| §6 | LXC + Knots |
| §7 | Node UI (nginx + API + Settings) |
| §8 | LuCI / TLS / admin password |
| §9 | Factory reset, LEDs (no M.2 wipe) |
| §10 | Build system (Makefile / Image Builder) |
| §11 | Factory M.2 imaging + identity regen |
| §12 | Wi‑Fi (future) / extension hooks |
| §13 | Test expectations |

---

## 1. Architecture overview

| Layer | Technology | Notes |
|-------|------------|-------|
| Host OS | OpenWrt (latest stable BPI-R4) | LuCI, firewall, DHCP, DNAT, node UI |
| Product version | `{openwrt}.{knots}` e.g. `24.10.xx.28.xx` | R1a |
| Node runtime | **LXC** | Single container, one DMZ IP |
| Bitcoin | Knots **`bitcoind`** | Unpruned; `disablewallet=1` until P6 |
| Data | M.2 NVMe **1 TB**, ext4 `@/mnt/bitcoin` | Bind-mount into LXC |
| Bitcoin pin | Knots **`v29.3.knots20260507`** (bundled; **default node is Core**, B15) | Non-RDTS (B4a); product `24.10.8.29.3` |
| Bitcoin Core pin | **`v29.5`** (factory default; replaces an older factory pin on the M.2 at boot) | Shared datadir with Knots (B15–B17); user may install other releases (B19–B21, U11) |
| Node UI | **nginx** on OpenWrt | HTTPS `:443` (HTTP `:80`→HTTPS) → RPC `21.21.21.21:8332` |
| LuCI | **uhttpd** on OpenWrt | `:8080` / `:8443` (linked from dashboard) |
| Bring-up (prod) | **eMMC boot** (R5) | SD = factory/lab install only (R5a); SD GPT production matches eMMC (**R5b**, `ROOTFS_PARTSIZE_MIB`) |
| SPI-NAND | Bootloader / recovery | Not full LXC+Knots rootfs |

```
┌─────────────────────────── OpenWrt (node-router) ───────────────────────────┐
│  br-lan 192.168.1.254/24   DHCP .100–.200                                    │
│    nginx Knots UI :80/:443     LuCI :8080/:8443                              │
│  WAN (DHCP, stock OpenWrt role) ── DNAT :8333 ──┐                            │
│  DMZ veth 21.21.21.1 ───────────────────────────┼──────────────┐             │
│                                                 ▼              ▼             │
│                                        ┌── LXC knots 21.21.21.21/24 ──┐      │
│                                        │ bitcoind :8333  :8332 RPC      │      │
│                                        │ datadir ← /mnt/bitcoin         │      │
│                                        └────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Repository layout (target)

```
bpi-r4_v3.0/
├── REQUIREMENTS.md
├── TECH_SPEC.md
├── Makefile                      # top-level: fetch IB, build image, bake rootfs
├── docs/
│   ├── AS_BUILT.md
│   └── SCOPE_GAPS_REPORT.md
├── build/
│   ├── imagebuilder.mk           # download/pin OpenWrt Image Builder
│   ├── packages.txt              # extra OpenWrt packages
│   └── version.env               # OPENWRT_VER KNOTS_VER → PRODUCT_VER
├── files/                        # OpenWrt root overlay → Image Builder FILES=
│   ├── etc/
│   │   ├── banner
│   │   ├── config/
│   │   │   ├── network           # optional seed; prefer uci-defaults
│   │   │   ├── firewall
│   │   │   ├── dhcp
│   │   │   ├── system            # hostname node-router
│   │   │   └── nginx             # or nginx conf under nginx/
│   │   ├── uci-defaults/
│   │   │   ├── 90-knots-network  # LAN .254, DHCP, DMZ veth, WAN stock
│   │   │   ├── 91-knots-firewall
│   │   │   ├── 92-knots-password # root → knotsnode21
│   │   │   └── 99-bitcoin-node   # first-boot orchestration (one-shot)
│   │   ├── nginx/
│   │   │   └── conf.d/knots-ui.conf
│   │   └── knots/
│   │       └── node-ui.env       # RPC host/port (no secrets)
│   ├── usr/
│   │   ├── libexec/knots/
│   │   │   ├── storage-prepare.sh
│   │   │   ├── lxc-ensure.sh
│   │   │   ├── knots-start.sh
│   │   │   ├── status-api.sh     # CGI or json emitter for /api/status
│   │   │   ├── identity-regen.sh
│   │   │   └── factory-reset.sh
│   │   └── sbin/
│   │       └── knots-storage     # thin CLI: prepare only (no wipe — S7)
│   └── www/
│       └── knots/                # static HTML/JS for node UI
├── lxc/
│   ├── config.in                 # LXC template → installed under /srv/lxc/knots/
│   ├── rootfs-build.sh           # debootstrap + install Knots
│   └── bitcoin.conf              # baked defaults
├── factory/
│   ├── capture-m2.sh             # golden → data image
│   └── flash-m2.sh
└── tests/
    ├── host/                     # host-side checks (make test-host)
    └── device/smoke.sh           # on-device smoke checks mapped to §13
```

---

## 3. Addressing, ports, DHCP

| Item | Value |
|------|-------|
| Hostname | `node-router` |
| Product version | `{openwrt}.{knots}` |
| LAN | `192.168.1.0/24` |
| LAN IP | `192.168.1.254` |
| DHCP pool | `192.168.1.100` – `192.168.1.200` |
| WAN | DHCP client (stock OpenWrt WAN) |
| DMZ router | `21.21.21.1` + `fd21:21:21::1` (veth/bridge end; **no services**) |
| DMZ Knots | `21.21.21.21/24` (**as-built lock**; was `/32`) + `fd21:21:21::21/64` |
| Admin user/pass | `root` / `knotsnode21` (testing) |

### 3.1 Physical ports (R12)

**Lock:** Stock OpenWrt BPI-R4 DSA assignment for the pinned release — **no custom remap**.

**OpenWrt 24.10.8 stock BPI-R4** (`board.d/02_network`):

| Role | Stock members |
|------|----------------|
| LAN (`br-lan`) | `lan1 lan2 lan3 eth1` |
| WAN | `wan eth2` |

Appliance overlays **only** change addresses/services on those stock roles (LAN → `.254`, DHCP pool, add DMZ veth). They do **not** reassign which jack is WAN vs LAN.

### 3.2 Service ports

| Listener | Where | Port |
|----------|-------|------|
| Node UI HTTP→HTTPS | OpenWrt LAN | **80** → **443** |
| LuCI HTTP/HTTPS | OpenWrt LAN | **8080→8443** / **8443** |
| Node UI HTTP/HTTPS | OpenWrt LAN | **80→443** (except CA/`/tls/*`) / **443** |
| Legacy node UI redirect | OpenWrt LAN | **21443** → `https://192.168.1.254/` |
| Knots P2P | LXC DMZ | **8333** |
| Knots RPC | LXC DMZ | **8332** |
| SSH | OpenWrt LAN (dev) | 22 |

---

## 4. UCI network / firewall / DHCP

Applied via `files/etc/uci-defaults/90-knots-network` and `91-knots-firewall` (idempotent; delete self after run).

### 4.1 Network sketch

```sh
# Hostname
uci set system.@system[0].hostname='node-router'

# LAN — keep stock br-lan device membership; change addressing only
uci set network.lan.ipaddr='192.168.1.254'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.proto='static'

# WAN — leave stock proto dhcp / device assignment

# DMZ link (bridge br-dmz; as-built /24, not /32 point-to-point)
uci set network.dmz=interface
uci set network.dmz.proto='static'
uci set network.dmz.device='br-dmz'
uci set network.dmz.ipaddr='21.21.21.1'
uci set network.dmz.netmask='255.255.255.0'
```

LXC side: `21.21.21.21/24`, gateway `21.21.21.1` (see §6.2).

> **As-built lock:** DMZ is a `/24` link (`21.21.21.1/24` router, `21.21.21.21/24` container) on `br-dmz` — no `dmz_route` /32 host route (M13 drift note; matches `files/etc/uci-defaults/90-knots-network` and `lxc/config.in`).

### 4.2 DHCP sketch

```sh
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='101'          # .100 through .200 inclusive
uci set dhcp.lan.leasetime='12h'
# ensure .254 never offered (static on router)
```

### 4.3 Firewall sketch

Zones: `lan`, `wan`, `dmz`.

| Rule | Spec |
|------|------|
| WAN → DMZ DNAT | TCP 8333 → `21.21.21.21:8333` (IPv4, family ipv4) |
| WAN → DMZ DNAT IPv6 | TCP 8333 → `fd21:21:21::21:8333` (family ipv6) — **N6a**; no other WAN→DMZ IPv6 ports |
| DMZ → wan | ACCEPT forward (egress allow-any v1) |
| lan → device | ACCEPT input 80, 443, 8080, 8443, 21443 (+ 22 on dev) |
| wan → device | REJECT 80/443/8080/8443/21443/SSH |
| lan → dmz | REJECT by default |
| device → dmz | ACCEPT TCP 8332 (UI/RPC) |
| UPnP / miniupnpd | Disabled / not installed |

```sh
# DNAT example (IPv4)
uci add firewall redirect
uci set firewall.@redirect[-1].name='knots-p2p'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='8333'
uci set firewall.@redirect[-1].dest='dmz'
uci set firewall.@redirect[-1].dest_ip='21.21.21.21'
uci set firewall.@redirect[-1].dest_port='8333'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].family='ipv4'
uci set firewall.@redirect[-1].target='DNAT'

# DNAT example (IPv6) — N6a
uci add firewall redirect
uci set firewall.@redirect[-1].name='knots-p2p-ipv6'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='8333'
uci set firewall.@redirect[-1].dest='dmz'
uci set firewall.@redirect[-1].dest_ip='fd21:21:21::21'
uci set firewall.@redirect[-1].dest_port='8333'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].family='ipv6'
uci set firewall.@redirect[-1].target='DNAT'
```

**DMZ IPv6 (N6a):** `network.dmz` has `ip6addr=fd21:21:21::1/64`; LXC `lxc.net.0.ipv6.address=fd21:21:21::21/64` gateway `fd21:21:21::1`. bitcoind `bind=21.21.21.21` and `bind=[fd21:21:21::21]`; `rpcbind` IPv4-only.
---

## 5. Storage (M.2) + first-boot

### 5.1 Constants

| Item | Value |
|------|-------|
| Device | `/dev/nvme0n1` |
| Partition | `/dev/nvme0n1p1` |
| FS | ext4 |
| Mount | `/mnt/bitcoin` |
| Datadir | `/mnt/bitcoin` (mount-root layout — **as-built lock**, D31; was `/mnt/bitcoin/bitcoin`) |
| Markers | `/mnt/bitcoin/.storage-prepared`, `/mnt/bitcoin/.factory-ready` |
| Low-space warn | &lt; **100 GiB** free |

### 5.2 `storage-prepare.sh` algorithm

```
if ! exists /dev/nvme0n1 → FAIL_CLOSED (status=error_no_disk)
if mounted ok AND (.factory-ready OR .storage-prepared) → ensure fstab; exit 0
if has valid ext4 + marker → mount; exit 0
else:
  stop knots if running
  wipe/create GPT one Linux partition
  mkfs.ext4 -F /dev/nvme0n1p1
  mount → /mnt/bitcoin
  mkdir -p /mnt/bitcoin/bitcoin
  touch .storage-prepared
  persist uci/fstab mount
```

### 5.3 First-boot orchestration (`99-bitcoin-node`)

One-shot uci-defaults / first-boot script:

1. Ensure hostname, password, network, firewall already applied (90/91/92).
2. Run `storage-prepare.sh`.
3. On success: `lxc-ensure.sh` (network + rootfs present).
4. If `.factory-ready`: run `identity-regen.sh` once (flag `/etc/knots/identity-regen.done`).
5. `knots-start.sh` (start LXC + bitcoind).
6. Enable nginx knots UI + status API.
7. Touch `/etc/knots/first-boot.done`; script must not re-format on later boots.

### 5.4 No on-device M.2 wipe (S7 / U8 / D4)

The appliance **must not** ship `storage-wipe.sh`, wipe CGI, `storage.html`, or `knots-storage wipe`. Retail M.2 is **factory-imaged** (§11 / **S5**). Empty disks use **prepare** only:

```
knots-storage prepare
```

Implementation: `/usr/libexec/knots/storage-prepare.sh`.

---

## 6. LXC + Bitcoin Knots

### 6.1 Container identity

| Item | Value |
|------|-------|
| Name | `knots` |
| Path | `/srv/lxc/knots/` |
| Rootfs | Debian stable (from `lxc/rootfs-build.sh`) |
| IP | `21.21.21.21/24` (**as-built lock**; was `/32`) |
| Gateway/peer | `21.21.21.1` |
| Autostart | After storage prepare succeeds |

### 6.2 LXC config sketch (`lxc/config.in`)

```
lxc.uts.name = knots
lxc.net.0.type = veth
lxc.net.0.link = br-dmz
lxc.net.0.flags = up
lxc.net.0.ipv4.address = 21.21.21.21/24    # as-built /24 link (was /32)
lxc.net.0.ipv4.gateway = 21.21.21.1
lxc.mount.entry = /mnt/bitcoin mnt/bitcoin none bind,create=dir 0 0
lxc.start.auto = 0                          # as-built: storage-gated start via knots-start.sh
```

As-built locks (match `lxc/config.in`): `/24` DMZ addressing; datadir bind of the mount root `/mnt/bitcoin` (D31); `lxc.start.auto = 0` so the container starts only after the storage gate. Exact veth/bridge plumbing is implemented in `lxc-ensure.sh` to match OpenWrt `network.dmz`.

### 6.3 Knots install (rootfs bake)

- Install Knots from pinned release (binary/deb/upstream artifact — record method in AS_BUILT).
- Unit/service: `bitcoind` enabled inside container.
- Config: `/etc/bitcoin/bitcoin.conf` in the LXC with `datadir=/mnt/bitcoin` (**as-built lock**, D31).

### 6.4 `bitcoin.conf` baseline

```
prune=0
disablewallet=1
txindex=0

listen=1
server=1
port=8333
rpcport=8332

bind=21.21.21.21
bind=[fd21:21:21::21]
rpcbind=21.21.21.21
rpcallowip=21.21.21.0/24    # as-built /24 (router .1 + local bitcoin-cli .21)

# RPC auth: cookie (preferred v1) — see §6.5
# rpcuser/rpcpassword NOT used

dbcache=1024                # as-built: BPI-R4 4 GiB RAM headroom (was 2048)
datadir=/mnt/bitcoin        # as-built mount-root layout (D31)
```

As-built locks (match `lxc/bitcoin.conf`): `rpcallowip=21.21.21.0/24`, `dbcache=1024`, `datadir=/mnt/bitcoin`, `listenonion=0` (clearnet-only v1, avoids the onion/clearnet shared-bind warning).

Clearnet only for v1 (no Tor required).

### 6.5 RPC auth — cookie (implement default)

**Chosen v1 method: cookie file.**

| Path | Role |
|------|------|
| `/mnt/bitcoin/.cookie` (datadir root, D31) | Written by `bitcoind` |
| OpenWrt UI helper reads via root-only access | `status-api.sh` runs as root / specific group |

Rules:

- Cookie **not** world-readable.
- LAN hosts cannot reach `:8332`.
- Only OpenWrt host `21.21.21.1` allowed (`rpcallowip`).
- Alternate `rpcauth` path reserved if cookie bind proves awkward; document switch in AS_BUILT if used.

### 6.6 Start gating

`knots-start.sh`:

1. Abort unless `/mnt/bitcoin` mounted and datadir writable.
2. Abort unless LXC rootfs present.
3. `lxc-start -n knots` (or equivalent).
4. Wait for RPC cookie + `getblockchaininfo` success (timeout → status error).

---

## 7. Node UI (nginx + API)

### 7.1 nginx (primary `:80` / `:443` TLS)

- Primary: **`:443` TLS** + **`:80` → HTTPS**; optional **`:21443` → `https://$host/`**.
- Move LuCI/uhttpd to **`:8080` / `:8443`** so nginx owns 80/443.
- TLS: self-signed cert generated at first boot → `/etc/knots/tls/`.
- Root: `/www/knots/`.
- `location /api/status` → file/CGI from `status-api.sh`.
- Dashboard links to LuCI; LuCI menu links back to `https://192.168.1.254/`.

Do **not** proxy browser ports to RPC `:8332` as a raw TCP map.

### 7.2 `GET /api/status` JSON (minimum)

```json
{
  "product_version": "24.10.xx.28.xx",
  "hostname": "node-router",
  "knots": {
    "running": true,
    "verification_progress": 0.42,
    "blocks": 850000,
    "headers": 850000,
    "best_block_hash": "…",
    "peers": 8,
    "uptime_sec": 3600,
    "error": null
  },
  "storage": {
    "mounted": true,
    "path": "/mnt/bitcoin",
    "free_bytes": 400000000000,
    "low_space": false
  }
}
```

Fields sourced via `bitcoin-cli -rpcconnect=21.21.21.21 …` using cookie auth + `df` on `/mnt/bitcoin`.

### 7.3 Static UI

Minimal pages under `/www/knots/`: status (`index.html`), node software (`node.html`), **Settings** (`settings.html`). No wallet controls on Phase 2 primary nav (P6/Phase 3).

### 7.4 Settings — language + upgrade + bitcoin.conf + power (U12–U15, U18, U19, R14, B22–B23, NF9)

**Nav (U9/U12):** Node Status · Node software · **Settings** · Router settings (LuCI).

**Auth (U15):** Every mutating Settings action requires form fields `user` + `password` matching LuCI/`root` (**R13**) — including **UI language**, upgrade, conf save, and power controls. Verify via OpenWrt **`ubus call session login`**. LAN only (`REMOTE_ADDR` private/LAN or loopback — not WAN). WAN must fail closed. Read-only `status` / `conf` may omit re-auth.

**Busy / status (U2):** Reuse `set_node_busy` / `clear_node_busy` from `node-impl-lib.sh` during upgrade, conf restart, and node stop/start so Node Status shows maintenance, not a false RPC error.

#### 7.4.0a UI language (U19 / U12)

| Item | Lock |
|------|------|
| Control | Settings **Language** panel — select shipped UI language (`regions.json` language ids). |
| Apply | `POST /api/settings?action=locale&confirm=LANGUAGE` with `lang=` + **U15**. |
| Effect | Writes `/etc/knots/ui-lang` (+ `/www/knots/ui-lang`); sets `luci.main.lang` via shared `setup_ui_lang_apply` (same mapping as Setup). Knots Node UI and LuCI both follow. |
| Timezone | Unchanged by this action (still Setup **U19** language & timezone step). |
| Confirm | Token **`LANGUAGE`**. |

#### 7.4.0 Power / node controls (U18)

| Item | Lock |
|------|------|
| Stop node | `POST …action=node_stop&confirm=STOP` — CGI returns JSON immediately and `cgi_setsid`s `bitcoind-ctl.sh stop` (F204 / F125). LXC may remain; poll `node_running` until `false`. |
| Start node | `POST …action=node_start&confirm=START` — only when the node is **stopped**. If `bitcoind_ctl_reindex_running`, refuse `reindex_in_progress`. If `bitcoind_ctl_bitcoind_alive`, refuse `already_running` (stop first). Status includes `reindex_running`; Settings greys ReIndex and shows **Reindex in progress** when true. Start + ReIndex enabled only when stopped and no reindex is running. When allowed: CGI returns JSON immediately and `cgi_setsid`s `bitcoind-ctl.sh start` (or `knots-start.sh start` if container down). Optional form `reindex=1` + `reindex_kind=chainstate` (default) or `full`. Reuses `bitcoind_ctl_reindex` (`-reindex-chainstate` or `-reindex`). Warning popup states the chosen action. Poll `node_running` / `reindex_running`. |
| Reboot device | `POST …action=reboot&confirm=REBOOT` — stop node first, then host `reboot`. |
| Shutdown device | `POST …action=shutdown&confirm=SHUTDOWN` — stop node first, then host `poweroff`. |
| Factory reset | `POST …action=factory_reset&confirm=RESET` **or** WPS hold ≥5 s — **first** arm `/reset.html` (**Factory Reset in Progress** / do-not-power-cycle), then soft **N3** reset (clear Setup markers; **never** wipe M.2). |
| LuCI / host reboot | Overlay `/sbin/reboot` and `/sbin/poweroff` call the same stop path before `busybox reboot` / `poweroff`. `/etc/init.d/knots` `STOP=15` remains a second line of defense. |
| Confirms | Tokens **`STOP`** / **`START`** / **`REBOOT`** / **`SHUTDOWN`** / **`RESET`** + **U15**. |

Do **not** wipe M.2 on any of these paths.

#### 7.4.1 Appliance upgrade (R14, U13, NF9)

| Item | Lock |
|------|------|
| Artifact | OpenWrt BPI-R4 **`*-bananapi_bpi-r4-squashfs-sysupgrade.itb`** (or `.bin` if board image uses that). Reject other filenames. |
| Transport | **LAN upload** — `POST /api/settings?action=upgrade&confirm=UPGRADE&sha256=<64hex>` with raw body = image. |
| SHA256 | **Required.** Operator pastes the published checksum (release page / `.sha256` line). Accept 64 hex digits, or `sha256sum` line form `HASH  filename` (first field used). UI may pre-check with Web Crypto; appliance **must** `sha256sum` the staged file and **refuse** `sysupgrade` on mismatch or missing hash. |
| Confirm | Type **`UPGRADE`**. |
| Size | Accept **8–256 MiB**; reject empty / out of range. |
| Staging | `/tmp/knots-upgrade.itb` (tmpfs) — **never** write the image onto `/mnt/bitcoin`. |
| Apply | Only after checksum match: `sysupgrade -v /tmp/knots-upgrade.itb` (keeps overlay config by default). **Must not** invoke storage wipe / mkfs / M.2 reimage (**NF9**). |
| Copy | UI states upgrade installs appliance software (new features / high-severity fixes; may later include a Phase 3 image) and **does not wipe the blockchain**; instructs pasting SHA256 from the trusted release channel. |
| Knots/Core binaries | Still only on **Node software** (**U11**). |

#### 7.4.2 bitcoin.conf (B22, B23, U14)

| Item | Lock |
|------|------|
| Path | Host: `/srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf` (LXC `/etc/bitcoin/bitcoin.conf`). |
| Read | `GET /api/settings?action=conf` → JSON with `safe` map + `raw` text (no auth). |
| Safe form allowlist | `dbcache` (64–2048), `maxconnections` (8–125), `maxmempool` (5–1000), `mempoolexpiry` (1–10080), `blocksonly` (0\|1), `peerbloomfilters` (0\|1). |
| Advanced | Raw editor; confirm **`ADVANCED`** plus auth; still run blocklist validation before write. |
| Hard-blocked keys | `datadir`, `prune`, `disablewallet`, `txindex`, `bind`, `rpcbind`, `rpcallowip`, `rpcport`, `port`, `rpcuser`, `rpcpassword`, `rpcauth`, `wallet`, `walletdir`, `listenonion` (product topology / Phase 2 wallet policy). |
| Save | Confirm **`SAVE`**, auth (**U15**), backup prior conf to `bitcoin.conf.bak`, write, then **restart bitcoind** via shared `bitcoind-ctl.sh restart` in a `cgi_setsid` worker (F204 — CGI must not wait on RPC). Same stop/start path as external-rpc. |
| External block | Preserve existing `# BEGIN knots-external-rpc` … `# END` block from `external-rpc.sh` when rewriting safe keys. |

#### 7.4.3 API surface

| Method | Action | Auth | Notes |
|--------|--------|------|-------|
| GET | `status` | no | product_version, conf path exists, upgrade hints, `node_running`, `lang`, power confirm tokens |
| GET | `conf` | no | safe + raw |
| POST | `locale` | yes | `lang=` + `confirm=LANGUAGE` — Knots UI + LuCI (**U19**) |
| POST | `conf_save` | yes | form: safe fields and/or `raw=`; `confirm=SAVE`; optional `advanced=1` + `confirm_advanced=ADVANCED` |
| POST | `upgrade` | yes | query `confirm=UPGRADE` + **`sha256=`** (required 64 hex); body = image bytes; verify before sysupgrade |
| POST | `node_stop` | yes | `confirm=STOP` — stop bitcoind (**U18**) |
| POST | `node_start` | yes | `confirm=START` — start bitcoind (**U18**); optional `reindex=1` + `reindex_kind=chainstate\|full` (**B24**) |
| POST | `reboot` | yes | `confirm=REBOOT` — stop node then reboot (**U18**) |
| POST | `shutdown` | yes | `confirm=SHUTDOWN` — stop node then poweroff (**U18**) |
| POST | `factory_reset` | yes | `confirm=RESET` — soft factory reset (**N3**); clears Setup markers; never wipes M.2; returns `expected_seconds` for UI progress |

Nginx: `location /api/settings` and `/api/node` on **both** `:80` and `:443` → `127.0.0.1:21444` (uhttpd CGI). HTTP must proxy these prefixes so a catch-all HTTPS 302 does not turn POST into GET (F204). `client_max_body_size` ≥ 256m for upgrade.

#### 7.4.4 Code reuse (mandatory)

| Need | Reuse |
|------|--------|
| CGI JSON helpers | `cgi-lib.sh` (`cgi_headers`, `fail_json`, `ok_raw`, `urldecode_soft`, `cgi_setsid`) |
| JSON escape / RPC wait | `rpc.sh` (`json_escape`, `knots_rpc`) |
| Maintenance banner | `node-impl-lib.sh` (`set_node_busy`, `clear_node_busy`) |
| bitcoind restart / stop / start | `bitcoind-ctl.sh` (same path as external-rpc / conf save) |
| Full container stop | `knots-start.sh stop` (init.d + reboot wrapper) |
| Upload streaming | Same POST-body → file pattern as `node-impl-api.sh` install |
| Nav / brand / theme | `shell.js`, `theme.js`, `app.css` |

Do **not** invent a second upload, restart, or stop stack.

### 7.5 Chainstate reindex recovery (B24, U16)


**Detect** (any of):

- `bitcoind` not running **and** `/mnt/bitcoin/debug.log` (tail) matches: `Error initializing block database`, `Please restart with -reindex`, `-reindex-chainstate to recover`, or `Corrupted block database detected`
- `/tmp/knots/knots.status` = `needs_reindex` (set by `knots-start.sh` after failed start when log matches)

**Status JSON** additions:

```json
"recovery": {
  "needs_reindex": true,
  "kind": "chainstate",
  "hint": "Node cannot start until the chain database is repaired."
}
```

While `-reindex-chainstate` / `-reindex` is in bitcoind argv (host or LXC) **or** `/tmp/knots/reindex.active` is set **and** tip is not yet caught up: `maintenance.active=true`, `op=reindex`, message explains validation in progress (not a fresh download). When verification is at tip, drop reindex maintenance even if argv still lists the flag.

**API:** `POST /api/node?action=reindex_chainstate&confirm=REINDEX` (LAN only). Reuse `bitcoind-ctl.sh reindex-chainstate`, `set_node_busy`, existing node CGI.

**UI (Node Status):** Modal/panel with required copy:

1. Something went wrong with the local chain database; the node will not start until it is repaired.  
2. This **re-validates / rebuilds chainstate from blocks already on the M.2** — it is **not** downloading the blockchain again.  
3. Can take many hours; keep power on.  
4. Confirm by typing **REINDEX**.

Default action: **`-reindex-chainstate`**. Node Status (**U16**) stays chainstate-only. Settings Start (**U18**) may offer full **`-reindex`** as “Also rebuild the block index” after a warning popup; default dropdown value remains Repair chain database.

### 7.6 First-run Setup wizard (U17, U19, R7, R10a, R13, U1b, N13)

**Playthrough (normative UX):** `docs/FIRST_RUN_UX.md`.

**Look and feel:** Same appliance UI as Node Status — reuse `shell.js` brand helpers, `theme.js` (**U1b**), `app.css`, and **`i18n.js`** (**U19**). No LuCI skin / separate theme. During Setup, omit primary nav; after complete, **U9** nav applies.

#### 7.6.1 Gate and markers

| Path | Meaning |
|------|---------|
| `/etc/knots/setup-complete` | Setup finished; node UI allowed |
| `/etc/knots/setup-password-done` | Password step completed this run |
| `/etc/knots/setup-locale-done` | Language & timezone applied (**U19**) |
| `/etc/knots/ui-lang` | Knots UI language code (e.g. `en`, `zh-cn`) |
| `/etc/knots/setup-pending/` | Staged Guided node / LAN / Wi‑Fi until Finish (mode 700; cleared on complete and factory reset) |

- If **`setup-complete` absent:** browser gate redirects to `/setup.html` (exceptions: Setup, `/tls.html`, static/i18n assets, APIs, CA, `/tls/*`).
- **Lab:** may `touch /etc/knots/setup-complete`. **Retail:** do not ship `setup-complete`.

#### 7.6.2 Reuse map (mandatory — no parallel stack)

| Concern | Reuse |
|---------|--------|
| JSON/CGI/LAN | `cgi-lib.sh` |
| Root password | `passwd` / `chpasswd` (factory pattern) |
| WAN / Wi‑Fi / LAN | UCI `network` / `wireless` / `dhcp` + netifd |
| Node impl | `node-impl.sh set` |
| Router timezone | UCI `system.@system[0].zonename` + `.timezone`; `/etc/localtime` via zoneinfo; `system reload`; Wi‑Fi `country` from catalog |
| LuCI language | UCI `luci.main.lang` + `luci-i18n-base-*` packages |
| Knots UI language | `/etc/knots/ui-lang` + `/www/knots/i18n/*.json` + `i18n.js` |
| HTTPS trust | N13 CA + `/tls/` scripts |
| Timezone catalog | `/www/knots/i18n/regions.json` (IANA zonename + POSIX TZ + ISO country for Wi‑Fi) |

#### 7.6.3 API — `GET|POST /api/setup`

| Action | Method | Behaviour |
|--------|--------|-----------|
| `status` | GET | + `lang`, `locale_done`, `zonename`, `country` |
| `locale` | POST | `lang`, `zonename` (required), `country` (from catalog / Wi‑Fi); apply U19 (sets router clock); touch `setup-locale-done` |
| `password` | POST | set root password now (never stage the secret) |
| `wifi` | POST | **stage** SSID/PSK/country; do **not** `wifi reload`; `wifi_reconnect=false` |
| `node` | POST | **stage** impl after binary check; do not switch `bitcoind` yet |
| `lan` | POST | **stage** LAN IP/mask/DHCP; do **not** `ifup`; `lan_moved=false` |
| `complete` / `quickstart` | POST | apply staged node+LAN+Wi‑Fi UCI; JSON first; **one** cutover (alias hold if LAN IP changed; deauth or radio reload); `wifi_reconnect` / `lan_moved` for the Finish wait page |

#### 7.6.4 Language codes (v1)

| Knots `ui-lang` | LuCI `luci.main.lang` | Package |
|-----------------|----------------------|---------|
| `en` | `en` | (default) |
| `es` | `es` | `luci-i18n-base-es` |
| `de` | `de` | `luci-i18n-base-de` |
| `fr` | `fr` | `luci-i18n-base-fr` |
| `zh-cn` | `zh_cn` | `luci-i18n-base-zh-cn` |
| `ja` | `ja` | `luci-i18n-base-ja` |
| `pt-br` | `pt_br` | `luci-i18n-base-pt-br` |

#### 7.6.5 Defaults

| Item | Value |
|------|-------|
| Default language | `en` until Setup locale step |
| Default zonename | `UTC` until Setup |
| Admin / Wi‑Fi password min | 8 (WPA2-Personal passphrase: **8–63** ASCII per IEEE 802.11i) |
| Default SSID | `rnode` (user-editable in Setup) |
| Factory Wi‑Fi PSK | `knotsnode21` (same **R13** factory password; IUE must replace it) |
| Factory Wi‑Fi country | `AU` until Setup locale (hostapd rejects `00`) |
| Wi‑Fi IUE reconnect | Finish only: one join-wait after staged SSID/PSK (and optional LAN IP) apply. Do not drop the factory AP on the Wi‑Fi or LAN steps. |

#### 7.6.6 Page / i18n

- Setup steps 0…8 (Welcome → **HTTPS trust** → Locale → Password → WAN → Wi‑Fi → Node → Advanced → Done).
  OS detect shows **only** the detected OS; optional “different computer/phone” reveals other OS tabs.
- `data-i18n="key"` attributes; `i18n.js` loads `/i18n/<lang>.json` with English fallback.
- Missing translation keys render English.
---

## 8. LuCI / TLS / admin password

| Item | Value |
|------|-------|
| LuCI | Packages in Image Builder; ports 80/443 on LAN |
| Password | Lab: `root` / **`knotsnode21`**. Retail: Setup (**U17**) forces change before complete. |
| LuCI TLS | Self-signed OK for v1; document browser trust |
| Node UI TLS | Separate or shared local CA under `/etc/knots/tls/` |

---

## 9. Factory reset, LEDs

### 9.1 Factory reset (`factory-reset.sh`)

1. Stop Knots/LXC gracefully (optional).
2. Reset UCI appliance defaults (re-run network/firewall seeds **or** restore `/etc/knots/factory-uci.tgz`).
3. Re-apply password `knotsnode21` (testing policy / **R13** lab default) and restore factory Wi‑Fi PSK **`knotsnode21`** on SSID **`rnode`** (**R7**).
4. Clear Setup markers (`setup-complete`, `setup-password-done`, `setup-locale-done`) so **U17** IUE runs again after reboot.
5. **Never** wipe or format M.2 (**N3**, **S7**) — no `--wipe-storage` flag.
6. Reboot.

#### 9.1.1 Hardware button (BPI-R4)

| Button (silkscreen) | Linux visibility | Behaviour |
|---------------------|------------------|-----------|
| **RST** | None — hard-wired to SoC reset | Instant hardware reboot only; **not** a config reset |
| **WPS** | `KEY_RESTART` → `/etc/rc.button/reset` | Short press (&lt;1 s): reboot. Hold ≥5 s: appliance `factory-reset` (soft **N3**, clear Setup markers, **no** M.2 wipe, **no** `jffs2reset`) |

Retail copy / DOC3: tell users to **hold WPS ~5 seconds** to restore defaults and re-run Setup. Do not claim the silkscreen RST button resets settings.

### 9.2 LED states

| State | Meaning | Pattern |
|-------|---------|---------|
| Booting | Host up, Knots not ready | `green:status` timer 1000/1000 ms |
| Syncing | `verificationprogress < 1` | `green:status` timer 200/200 ms |
| Synced | At tip / healthy | `green:status` solid on |
| Error | No disk / Knots down | `blue:wps` timer 400/400 ms (green off) |

GPIO line names locked in AS_BUILT **D32** (stock BPI-R4 LEDs).

### 9.3 Cron / procd

- Optional: `status-api` cache refresh every 30s.
- LED updater cron/procd every 30–60s reading same status.

---

## 10. Build system

### 10.1 `build/version.env`

```
OPENWRT_VER=24.10.x
KNOTS_VER=28.x
PRODUCT_VER=${OPENWRT_VER}.${KNOTS_VER}
TARGET=mediatek/filogic
PROFILE=bananapi_bpi-r4
```

### 10.2 Makefile targets (minimum)

| Target | Action |
|--------|--------|
| `make fetch-ib` | Download OpenWrt Image Builder for PROFILE |
| `make rootfs` | `lxc/rootfs-build.sh` → artifact under `lxc/out/` |
| `make overlay` | Stage `files/` + inject rootfs into overlay path |
| `make image` | Image Builder with `FILES=files` + `packages.txt` |
| `make version` | Print `PRODUCT_VER` |
| `make flash-sd DEVICE=/dev/sdX` | Write `*sdcard.img*` (operator-run) |

### 10.3 Image Builder packages (`build/packages.txt`)

Minimum set (adjust to feed availability):

- `luci`, `luci-ssl` (or equivalent)
- `nginx` / `nginx-ssl` (or `uhttpd` only for LuCI + separate nginx)
- `lxc`, `lxc-start`, `lxc-attach`, `liblxc` (as packaged)
- `block-mount`, `e2fsprogs`, `parted` / `sfdisk`, `blkid`
- `curl`, `ca-bundle`
- NVMe: `kmod-nvme` (if not already in profile)

### 10.4 Output artifacts

- `bin/targets/.../*bananapi_bpi-r4-sdcard.img.gz` — factory/dev install media (R5a); production partition sized per **R5b** (`ROOTFS_PARTSIZE_MIB` in `build/version.env`, applied by `make apply-ib-partsize`)
- `*bananapi_bpi-r4-squashfs-sysupgrade.itb` (+ SNAND/eMMC preloader/FIP artifacts as built by OpenWrt) — production eMMC install path (R5)
- Production runtime target: **eMMC** root; SPI-NAND not sized for full appliance rootfs

---

## 11. Factory M.2 imaging + identity regen (P4)

### 11.1 Golden capture (`factory/capture-m2.sh`)

From a synced reference unit (same Knots version):

1. Stop `bitcoind`.
2. Capture either:
   - **A:** datadir tarball of `blocks/`, `chainstate/`, (optional indexes), plus `.factory-ready` metadata, **or**
   - **B:** whole-disk `dd` of nvme0n1 compressed.
3. Record tip height/hash + Knots version in `.factory-ready` JSON.

Prefer **A (datadir)** for flexibility; support **B** if cloning speed matters.

### 11.2 Flash (`factory/flash-m2.sh`)

Write image to blank 1 TB M.2 on factory station; verify checksum.

### 11.3 Identity regen (first boot with `.factory-ready`)

`identity-regen.sh` removes/regenerates **at least**:

- `peers.dat`
- `onion_v3_private_key` / Tor state if present
- `wallet*` / walletdir (should be absent with `disablewallet=1`)
- `.cookie` (recreated on start)
- Any node-local banlists that should not be cloned (product choice: delete `banlist.json` if present)

Keep: `blocks/`, `chainstate/`, indexes, `.factory-ready`.

Set `/etc/knots/identity-regen.done` so it runs once per system.

---

## 12. Wi‑Fi (future) / extension hooks

- Wi‑Fi in Setup; default SSID **`rnode`** when hardware present (editable); password required 8–63.
- P6/P7: keep RPC + UI modular; do not put wallet into P1–P5 UI.
- W5 only: documented hooks (env files, package drop-ins under `/usr/libexec/knots/hooks.d/`).

---

## 13. Test expectations

`docs/TEST_SUITE_MATRIX.md` (G34) maps every ID below to its script and `make` target — it is the normative test index. P1–P3 smoke must prove:

| ID | Check |
|----|-------|
| T-LAN-1 | Host `192.168.1.254`; DHCP issues `.100–.200` |
| T-UI-1 | LuCI **8080/8443** with `root` / `knotsnode21` (80/443 = node UI, D29) |
| T-UI-2 | `https://192.168.1.254/` serves Knots UI; `/api/status` JSON; LuCI on `:8080` |
| T-FW-1 | WAN DNAT 8333 → DMZ (IPv4 + IPv6 N6a); WAN cannot open 80/443/8080/8443/8332 |
| T-FW-2 | LAN cannot open arbitrary DMZ ports; router→8332 works for API |
| T-STO-1 | Empty M.2 prepares; second boot mount-only |
| T-STO-2 | Missing M.2 → Knots not started; API/LED error |
| T-STO-3 | Wipe tooling **absent** per S7 (S8/S9 retired) — assert no `storage-wipe.sh`, no wipe CLI verb, no wipe CGI, no Storage nav (`tests/host/test-wipe-guards.sh`) |
| T-NODE-1 | LXC up at `21.21.21.21`; `disablewallet=1`; clearnet peers path |
| T-VER-1 | Banner/API reports `PRODUCT_VER` `{openwrt}.{knots}` |

Real data / real board when testing storage and sync (REQUIREMENTS T1–T2).

---

## 14. Implementation order (build)

1. `build/version.env` + Makefile `fetch-ib` / `image` with LuCI + LAN `.254` + password  
2. Storage prepare + first-boot gating  
3. DMZ veth + firewall DNAT/egress  
4. LXC rootfs + Knots + cookie RPC  
5. nginx UI + `/api/status`  
6. Factory reset (no wipe — S7)  
7. Factory M.2 scripts + identity regen  
8. LEDs + test matrix file  

Record concrete `PRODUCT_VER` and stock port list from the IB in `docs/AS_BUILT.md` on first green image.
