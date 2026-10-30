# BPI-R4 Bitcoin Knots Appliance v3.0 — Requirements

**Version:** 3.0  
**Date:** 2026-08-12  
**Status:** Authoritative  
**Product:** BPI-R4 Bitcoin Knots Appliance  
**Folder:** `bpi-r4_v3.0`

**Authority:** This document is the sole product authority. `TECH_SPEC.md` elaborates. `docs/AS_BUILT.md` records implementation locks and fixes. `initial_requirement.md` is historical concept seed only.

**Product phases (owner-facing):** see §2.  
**Phase 1 freeze:** Baseline Build 1 — `docs/BASELINE_BUILD_1.md` (artifact + SHA256).  
**Phase 2 (current):** Node SKU — OpenWrt + full node + Knots↔Core switch; **no** Wallet / External apps / Lightning / Privacy product tabs — `docs/PHASE2_NODE_SKU.md`.  
**Phase 3 (deferred):** Reinstate those modules — `docs/PHASE3_REQUIREMENTS.md` (formerly “Phase 2 Build” / P2B-*).

If a request contradicts this document, **stop and amend this document first**.

---

## 1. Product vision

A **plug-and-play home router** that replaces a normal consumer router **and** runs a **Bitcoin Knots full node**, aimed at:

1. People who want to run a full node but **do not have deep technical skills**.
2. Anyone who wants to **replace their router** and **support the Bitcoin network**.

The appliance must feel like a router first: power on, connect WAN/LAN, browse LuCI on the LAN, and the node works without manual Linux administration.

**Current focus:** **Product Phase 2** — deploy the Node SKU (router + Knots/Core + status UI + implementation switch) to the lab unit **without wiping M.2 chain data**, then install that system image to **eMMC** (**R5**/**R5a**). Wallet / External / Lightning / Privacy tabs are **out of Phase 2** and return in **Phase 3**.

### 1.1 Positioning

| Audience need | Product response |
|---------------|------------------|
| Replace ISP/home router | Latest stable OpenWrt + LuCI; LAN `192.168.1.0/24` (gw `.254`); separate Node DMZ; Wi‑Fi later |
| Run a full (unpruned) node without ops burden | First-boot automation, M.2 storage prep, Knots auto-start |
| See node health simply | Appliance node web UI on **internal LAN** (Knots has no native web UI) |
| Choose Knots or Core | Shared datadir switch (**B15–B18**, **U7**/**U7a**) in Phase 2; user-installable versions (**B19–B21**, **U11**) |
| Grow into self-custody later | **Phase 3** reinstates Knots default wallet + external wallets + Lightning + privacy |

---

## 2. Phased scope

### 2.1 Product release phases (authoritative)

Naming: **Phase 1 / Phase 2 / Phase 3** below are **product releases**. They are **not** the same as build-layer IDs **P1–P5** in requirement tables (those remain engineering layers).

| Product phase | Codename | Scope | Status |
|---------------|----------|-------|--------|
| **Phase 1** | Baseline Build 1 (BB1) | Frozen known-good: OpenWrt router + Knots full node + status UI (historical ports/lineage in `docs/BASELINE_BUILD_1.md`) | **Locked** — do not overwrite `bin/baselines/` artifact |
| **Phase 2** | Node SKU | Phase 1 contracts **plus** Knots↔Core switch, **user install/replace of Knots/Core binaries** (**B19–B21**, **U11**), **Settings** (appliance LAN upgrade **R14**/**U13**, bitcoin.conf **B22**/**B23**/**U14**, auth **U15**, **NF9**), primary UI on 80/443, LuCI coexistence, theme, eMMC production boot path. **Rollback / omit** product surfaces for Wallet, External apps, Lightning, and Privacy tabs (and their enabled runtimes) until a Phase 3–capable image is installed and authorized. **`disablewallet=1`**. Preserve M.2 `blocks/` + `chainstate/` on deploy and eMMC install / Settings upgrade. | **Authorized — current deploy target** |
| **Phase 3** | Custody modules | Reinstate Wallet, External apps, Lightning, and Privacy tab functionality (former P2B-A/B/C/D). Elaboration: `docs/PHASE3_REQUIREMENTS.md`. | **Requirements locked — implement only when owner authorizes Phase 3** |

**Phase 2 rule:** Shipping Phase 2 means the primary Node Dashboard nav exposes **Node Status** and **Node software** (plus LuCI link) — **not** Wallet / External apps / Lightning / Privacy. Residual HTML/API files may remain on disk for Phase 3 reinstatement but must not be primary UX. Optional modules (CLN, JoinMarket, LAN external RPC) must be **stopped / disabled** in the Phase 2 runtime posture.

**Chain-preserve rule (Phase 2 deploy / eMMC):** System image updates (overlay push, sysupgrade, SD→eMMC install) must **not** format or wipe `/mnt/bitcoin` chain data. The appliance ships **no** on-device M.2 wipe path (**S7**). Mount-only when `.factory-ready` / `.storage-prepared` / valid FS present (**S3**). Retail/factory units use **pre-imaged** M.2 data (**S5**, **NF5**) so customers avoid full IBD.

**Architecture rule:** Phase 2 must not break Phase 1 contracts. Prefer clear service boundaries so Phase 3 modules can return without redesigning router/node core.

### 2.2 Build layers (engineering IDs in tables)

| Layer | Scope | Product mapping |
|-------|-------|-----------------|
| **P1** | OpenWrt system image, LuCI, first-boot, M.2 prepare/mount | Phase 1 / Phase 2 |
| **P2** | Bitcoin full node (LXC), WAN sync, auto-start, storage contract | Phase 1 / Phase 2 |
| **P3** | Firewall/DMZ, appliance status UI, LED, factory reset, Knots↔Core UI | Phase 1 / Phase 2 |
| **P4** | Production M.2 data imaging + identity regeneration + factory seal | Phase 2 factory track |
| **P5** | Production seal guards + verify no on-device M.2 wipe surfaces | Phase 2 (factory imaging is external — **D3**/**S5**) |
| **P6** | Knots **default wallet** on LAN UI | **Phase 3** only |
| **P7** | Lightning and/or **plug-and-play external wallet** integrations | **Phase 3** only |
| **P2B-D** | Privacy payments / on-appliance mixing (**M-B**) | **Phase 3** only |

---

## 3. Scope boundaries

### 3.1 In scope (Phase 2 / build layers P1–P5)

Everything in §4–§10 marked for Phase 1–2 / P1–P5, including Knots↔Core (**B15–B18**, **U7**, **U7a**), user version install (**B19–B21**, **U11**), Settings upgrade/conf/power (**R14**, **B22**/**B23**, **U12–U15**, **U18**, **NF9**), and eMMC production boot (**R5**, **R5a**).

### 3.2 Phase 3 (requirements locked; implement when authorized)

Authoritative elaboration: **`docs/PHASE3_REQUIREMENTS.md`** (historical filename stub: `docs/PHASE2_REQUIREMENTS.md` → redirects).

- **P2B-A (P6):** Knots default wallet UI/lifecycle.  
- **P2B-B (P7):** External wallet plug-in path.  
- **P2B-C (P7):** Lightning module.  
- **P2B-D:** Privacy payments — **M-B** (M1–M7).

Until Phase 3 is authorized, Phase 2 may keep **hooks/docs** only (**W5**) — not live product tabs.

### 3.3 Out of scope (do not build)

- Custodial / hosted wallet services or cloud key custody.
- Replacing Knots validation with trusted third-party HTTP indexers as chain source of truth.
- USB serial as the primary flash/build pipeline (optional debug console only).
- Requiring WAN SSH deploy for first install (factory path is local media flash per **R5**).
- Silent wipe of factory-sealed M.2 data images.
- On-appliance M.2 wipe UI, CGI, or CLI (repartition/reformat). Chain data is prepared by **factory imaging** (**S5**, **D3**) or empty-disk **prepare** (**S2**) only — never an end-user or shipping wipe tool (**S7**).
- Inventing closures for open items in `docs/SCOPE_GAPS_REPORT.md`.
- **During Phase 2:** shipping Wallet / External apps / Lightning / Privacy as primary product UX (those return in Phase 3).

---

## 4. Functional requirements

### 4.1 Router & platform

| ID | Phase | Description |
|----|-------|-------------|
| **R1** | P1 | Appliance is based on the **latest stable OpenWrt** release supported for BPI-R4 at build time. |
| **R1a** | P1 | **Product/build version** = OpenWrt + Bitcoin Core (the default node) + **appliance build number**, dotted form **`{openwrt}.{core}.{build}`**, e.g. **`24.10.8.29.5.119`** (from build 119; Release 1 = `24.10.8.29.3.118` still used the Knots version). Increment **`build`** for each appliance image/release that changes product software (not for every local WIP). Record the concrete string in `docs/AS_BUILT.md` on each release/build. |
| **R2** | P1 | **LuCI** is installed and reachable on the **internal LAN** for normal router administration. |
| **R3** | P1 | Device functions as a home router: WAN uplink, LAN switching/routing, NAT as appropriate. |
| **R4** | P1 | Plug-and-play first boot: sensible defaults so a non-technical user can connect WAN + LAN and get online without CLI. **Retail** units also run the first-run Setup wizard (**U17**). |
| **R5** | P1 / Prod | **Production end position — system boots from onboard eMMC**, not microSD. Retail units shall run OpenWrt + appliance overlay (LuCI, LXC, Knots/UI) from **eMMC** with a squashfs (or equivalent OpenWrt) root and writable overlay. **microSD is factory/lab install media only** and must not be required in the shipped product. **SPI-NAND (128 MB)** is for bootloader / install / recovery stepping-stone — **not** the full appliance rootfs (too small for LXC+Knots). **M.2** remains blockchain datadir only (**B5**). |
| **R5a** | P1 / Factory | **Factory / developer install path:** PC builds an SD-flashable image (and related OpenWrt BPI-R4 artifacts: e.g. `squashfs-sysupgrade.itb`, SNAND/eMMC bootloader pieces). Operator boots from SD → installs to SPI-NAND as needed → installs system to **eMMC** → sets boot select to eMMC → removes SD. Dev may continue to boot from SD for iteration; that is not the production SKU. |
| **R5b** | P1 / Factory | **SD emulates eMMC geometry for lab/prod parity:** Image Builder **`CONFIG_TARGET_ROOTFS_PARTSIZE`** (product lock: **`ROOTFS_PARTSIZE_MIB`** in `build/version.env`) sizes the **production** GPT partition identically for the SD card image and the embedded eMMC GPT. Target is the usable onboard **~8 GB eMMC** (≈7.3 GiB media; production starts at 64 MiB). Lab SD boot therefore presents the same **squashfs (`/rom`) + fitrw overlay** capacity model as production eMMC. Excess SD capacity beyond that GPT remains unused. SPI-NAND stays 128 MB bridge-only (**R5**). |
| **R6** | P1 | Default LAN is **`192.168.1.0/24`**; router LAN gateway/address **`192.168.1.254`**. |
| **R7** | Phase 2 | **Wi‑Fi default AP + first-run Setup (**U17**):** When Wi‑Fi hardware/driver is present, first boot enables a LAN AP **SSID `rnode`**, WPA2-Personal passphrase **`knotsnode21`** (same documented factory password as **R13**). The user may start Setup on a **LAN cable** **or** by joining **`rnode`**. Setup collects **SSID** (default **`rnode`**, user-editable), a **new Wi‑Fi password** (required; **WPA2-Personal 8–63** ASCII; **must not** be the factory password), and **country/region**. Apply via stock UCI `wireless` to all radios/AP ifaces (no parallel stack). Factory radios use country **`AU`** until Setup locale (hostapd rejects world `00`, which leaves the AP at 0 dBm). **SSID/PSK (and Guided LAN IP) are staged until Finish** — the factory AP stays up through the wizard so Windows and Linux Wi‑Fi clients are not dropped mid-flow. One cutover at Finish (Quick Start or Guided) applies wireless UCI, then **one** join-wait if the client is a Wi‑Fi station. Ethernet clients are not dropped. If no radio: skip with clear copy. Deep Wi‑Fi options remain in LuCI. |
| **R8** | P1 | Node DMZ is a **separate network** from LAN/WAN. Link subnet **`21.21.21.0/24`** containing exactly **one** service host, **`21.21.21.21`**. Router DMZ link endpoint is **`21.21.21.1`** (reachability only — **not** a service host). DMZ addressing is **local-only**. |
| **R9** | P1 | LAN **DHCP server enabled**; pool **`192.168.1.100`–`192.168.1.200`** (must not assign `.254`). |
| **R10** | P1 | **WAN** is a **DHCP client** by default (typical home ISP/upstream router). |
| **R10a** | Phase 2 | **WAN in first-run Setup (**U17**):** Setup **auto-tries DHCP** on the stock WAN interface first. On success, show connected and continue (no ISP credentials). If no address after timeout, or the user chooses “ISP needs a username and password,” offer **PPPoE** (username/password) via stock UCI `proto pppoe`, then re-test. Allow **Skip for now** so password/Wi‑Fi/node steps are not blocked. Unusual ISP (VLAN, etc.) → point to LuCI. Do not invent a non-OpenWrt dialer. |
| **R11** | P1 | Default hostname is **`node-router`**. |
| **R12** | P1 | Physical **WAN vs LAN port mapping** follows the **standard OpenWrt BPI-R4** image defaults (stock DSA/UCI role assignment). Do not invent a custom port map. |
| **R13** | P1 / Phase 2 | **Testing / lab / factory defaults:** admin password **`knotsnode21`** (LuCI/`root`, Settings **U15**) and default Wi‑Fi PSK **`knotsnode21`** on SSID **`rnode`** (**R7**, **U6**). **Retail Setup (**U17**)** must change **both** before the wizard can complete. Do not invent other undocumented factory passwords. Private keys/RPC cookies still must not be committed. |
| **R14** | Phase 2 | **Appliance software upgrade (Settings):** User may install a new **appliance system image** (OpenWrt/sysupgrade-class artifact for this board) via **LAN upload** from Settings (**U13**). Upgrade purpose is to deliver **new product functionality** (including a future **Phase 3** feature build when that image is released and authorized) and/or **high-severity bug fixes** for shipped users. Must obey **NF8**/**NF9** (never wipe or rewrite M.2 `blocks/` / `chainstate/`). Invalid/wrong-board images fail closed. **SHA256 required:** operator must paste the published image checksum; appliance verifies the uploaded file matches **before** `sysupgrade` (**U13**). WAN must not trigger upgrade. |

### 4.2 Bitcoin Knots full node

| ID | Phase | Description |
|----|-------|-------------|
| **B1** | P2 | Runs an **unpruned full node** (`prune=0`; keeps full block history; not a light client) using the **selected** implementation (**B15**). |
| **B2** | P2 | Selected `bitcoind` starts automatically after storage is mounted and verified. |
| **B3** | P2 | Node uses **WAN / clearnet** for peer connections and block download / tip catch-up. **Tor/I2P not required for v1**. |
| **B4** | P2 | **Default** implementation version (Knots) is the second half of the product/build version (**R1a**); recorded with OpenWrt in `docs/AS_BUILT.md` on each build. Core pin recorded separately when shipped (**B16**). |
| **B4a** | P2 | **Pinned Knots build (default):** **`v29.3.knots20260507`** — official **non-RDTS / non-BIP-110** parallel ([bitcoinknots.org](https://bitcoinknots.org/files/29.x/29.3.knots20260507/)). Do **not** ship RDTS-enforcing `*20260508` builds unless REQUIREMENTS is amended. |
| **B5** | P2 | Node datadir lives on the **M.2** data volume (not overlay/SD root). Retail/default M.2 capacity is **1 TB**. |
| **B6** | P3 | Appliance exposes the **primary LAN node web UI on TCP `80` (HTTP→HTTPS) and `443` (HTTPS/TLS)** served from **OpenWrt (nginx)**; UI uses the active node’s RPC for status/health. Optional legacy **`21443`** may redirect to `https://192.168.1.254/`. |
| **B7** | P3 | **LuCI and the appliance node UI coexist** — both reachable on LAN. **Default browser entry** is the Knots dashboard on **80/443**; LuCI is secondary (see **U1**). |
| **B8** | P2 | Selected implementation runs as headless **`bitcoind`** inside **LXC**. `bitcoin-qt` is not the appliance UI path. |
| **B15** | P2 | User may choose **Bitcoin Knots** or **Bitcoin Core** as the full-node implementation. **Default is Core** (changed from Knots after external tester feedback, IUE v2 2026-09; Knots remains bundled and selectable). Choice **must persist across clean reboot and hard power loss**: store on M.2 (`/mnt/bitcoin/.node-impl`) and mirror to system (`/etc/knots/node-impl`); reconcile after mount before starting `bitcoind`. Never write a default choice onto an **unmounted** `/mnt/bitcoin` (that lands on overlay and can mask the real preference). |
| **B16** | P2 | **Pinned Core build (optional runtime):** **`v29.5`** from [bitcoincore.org](https://bitcoincore.org/bin/bitcoin-core-29.5/) (`bitcoin-29.5-aarch64-linux-gnu`). Record in AS_BUILT. |
| **B17** | P2 | **Shared blockchain datadir:** both implementations use the **same** M.2 datadir (`/mnt/bitcoin` contract) so the user can switch without re-downloading the chain. Switching stops the running `bitcoind` and starts the other against that datadir. |
| **B18** | P3 / Phase 2 | LAN UI exposes the implementation choice (status + switch) with an explicit confirm; WAN cannot change it. Phase 3 Knots-only modules (e.g. privacy) may be unavailable or gated while Core is active — surface that when those modules ship. Shared datadir means wallet files are **intended** to be the same across Knots/Core; switch UX must still apply **U7a** money-safety warnings when wallet dirs exist. |
| **B19** | P2 | User may **install or replace** Knots and/or Core binaries on the M.2 under `/mnt/bitcoin/node-bin/{knots,core}/` from an **official aarch64 Linux release tarball** (`*-aarch64-linux-gnu.tar.gz`). Factory pins (**B4a**, **B16**) remain the **shipped defaults** only; they must not permanently prevent the user from running another released version. Install must **not** wipe `blocks/` / `chainstate/` (**B17**, **NF8**). |
| **B20** | P2 | Before replacing an installed impl tree, retain the previous binaries for **rollback** (e.g. `/mnt/bitcoin/node-bin/{knots,core}.prev/`). UI/CLI exposes restore of the previous version with the same confirm discipline as a switch. |
| **B21** | P2 | Install path accepts **LAN upload** of the tarball to the appliance (primary). Optional WAN fetch by URL may be added later but is not required for acceptance. Refuse non-aarch64 / missing `bitcoind`. Prefer SHA256 verification when the user supplies a checksum (or a companion `.sha256` file). |
| **B22** | Phase 2 | **bitcoin.conf management (Settings):** User may view/edit the live Knots/Core conf used by the appliance (`/etc/bitcoin/bitcoin.conf` in LXC / product path in TECH_SPEC) from Settings (**U14**). Saving applies the file and **restarts** `bitcoind` after confirm (**U14**). Must not move `datadir` off the M.2 contract; must not weaken DMZ RPC bind / LAN exposure rules (**B11**, **N8–N10**). |
| **B23** | Phase 2 | Conf editor has two tiers: (1) **Safe form** of allowlisted knobs (TECH_SPEC list; e.g. `dbcache`, `maxconnections`, and similar non-topology options); (2) **Advanced raw editor** behind an extra explicit confirm. Hard-blocked / refused keys include at least: `datadir`, `rpcbind`, `rpcallowip` expansions beyond product policy, `bind`/`externalip` that break DMZ, `prune` enabling prune against **B1**, and wallet enablement while Phase 2 requires **`disablewallet=1`** (**B9**) unless Phase 3 is authorized and the installed image supports it. |
| **B24** | Phase 2 | **Chainstate / block-index recovery:** When `bitcoind` refuses to start and logs that a **`-reindex` / `-reindex-chainstate`** is required (e.g. “Error initializing block database”), the appliance must detect that condition, surface it on **Node Status** (**U16**), and offer a LAN-only **reindex-chainstate** action that rebuilds chainstate from existing `blocks/` **without** re-downloading the blockchain. Prefer **`-reindex-chainstate`** over full `-reindex`. **Settings Start (**U18**)** may offer full `-reindex` as an explicit second choice (“Also rebuild the block index”) after a warning popup; default remains `-reindex-chainstate`. Obey **NF8**/**NF9** (no M.2 wipe/format). |
| **B9** | P2 / Phase 2 | **Phase 2 ships `disablewallet=1`.** Phase 3 (P6) may enable wallet under controlled migration (**W8**). Leftover wallet directories on M.2 from lab/Phase 3 experiments must not be deleted by a normal Phase 2 deploy. |
| **B10** | P2 | RPC auth for UI→node: **cookie file** bind-mounted/shared to the router UI **or** `rpcauth` known only to UI (TECH_SPEC); never expose raw RPC to the whole LAN. |
| **B11** | P2 | Listen/bind: P2P **`8333`** on DMZ host (**IPv4 `21.21.21.21` and IPv6 `fd21:21:21::21`**, **N6a**); RPC **`8332`** only on DMZ IPv4 (`21.21.21.21`), reachable from router UI/proxy path — **not** bound/published on LAN or WAN IPv6. |
| **B12** | P2 | Baseline conf: unpruned; **txindex off** unless a later requirement needs it; **dbcache** sized for BPI-R4 RAM class (TECH_SPEC). |
| **B13** | P2 | If M.2 is **missing, unusable, or below usable capacity**: **fail closed** — do not start Knots; surface error via node UI/LED. |
| **B14** | P3 | Node UI warns when free space on M.2 is low (unpruned growth on 1 TB); do not silently enable prune. |

#### 4.2.1 Knots UI reality (locked understanding)

Bitcoin Knots itself provides:

| Interface | What it is | Appliance use |
|-----------|------------|---------------|
| **`bitcoind`** | Headless full node daemon | **Primary runtime** |
| **`bitcoin-cli`** | CLI against RPC | Ops/debug; not end-user UX |
| **JSON-RPC** | Local API for status/control/wallets | Consumed by appliance UI / future wallets |
| **`bitcoin-qt`** | Desktop GUI (X11/Wayland) | **Not used** on this headless router |
| **Native web UI** | None | Knots does **not** ship a browser UI |

Therefore “Knots interface” in this product means: **appliance web UI on LAN → Knots RPC** (Phase 2 status + node switch; Phase 3 wallet later). LuCI remains the **router** admin interface, reached from the Knots dashboard (and with a return link in LuCI).

### 4.3 Storage (M.2)

| ID | Phase | Description |
|----|-------|-------------|
| **S1** | P1 | On first boot, detect primary M.2 NVMe (default `/dev/nvme0n1`); design target **1 TB**. |
| **S2** | P1 | If disk is empty/unknown: partition, format **ext4**, mount at `/mnt/bitcoin`, persist mount, write `.storage-prepared`. |
| **S3** | P1 | If `.factory-ready` or `.storage-prepared` present with valid FS: **mount only — do not format**. |
| **S4** | P2 | Start Knots only after mount verification succeeds. |
| **S5** | P4 | Production may ship M.2 **data images** preloaded with `blocks/` + `chainstate/` (and optional indexes). |
| **S6** | P4 | On first boot of a cloned data image: regenerate node identity material; **never** treat cloned `peers.dat` / onion keys / wallets as shared identity. |
| **S7** | P5 | **No on-device M.2 wipe.** The appliance must **not** ship wipe UI (`storage.html`), wipe CGI (`/api/storage` wipe), or wipe CLI (`knots-storage wipe` / `storage-wipe.sh`). Retail/factory M.2 is **pre-imaged** (**S5**, **D3**, **NF5**). Empty/unknown disks still use first-boot **prepare** only (**S2**). |
| **S8** | — | **Retired** (was wipe mode B / reformat). Superseded by **S7**. |
| **S9** | — | **Retired** (was wipe confirmation / `--force-prod`). Superseded by **S7**. |

### 4.4 Security, network isolation, operations

| ID | Phase | Description |
|----|-------|-------------|
| **N1** | P3 | Knots runs in a **Node DMZ** on a network **completely separate** from LAN/WAN. The DMZ (link subnet `21.21.21.0/24`) contains **exactly one host**: **`21.21.21.21`**. No other DMZ service hosts. |
| **N2** | P3 | On **internal LAN** only: **appliance node UI (nginx)** on **TCP 80/443**; **LuCI (uhttpd)** on **TCP 8080/8443**. WAN management (LuCI/SSH/node UI) denied by default in production. |
| **N3** | P3 | Factory reset restores **system/router config** to clean baseline and **must never** wipe or format M.2 chain data (no `--wipe-storage` or equivalent). |
| **N4** | P3 | LED (or equivalent) status indicates at least: booting, syncing, synced/error (mapping in TECH_SPEC). |
| **N5** | P1–P5 | No secrets (RPC passwords, Wi‑Fi keys, factory seals) committed to git. |
| **N6** | P3 | From **WAN → DMZ**: port redirect/DNAT **TCP 8333 → `21.21.21.21:8333`** (Bitcoin P2P only). **IPv6:** same port only — redirect/DNAT **TCP 8333 → `fd21:21:21::21:8333`** (**N6a**). No other WAN→DMZ ports. |
| **N6a** | P3 / Phase 2 | **IPv6 P2P:** DMZ link uses product ULA **`fd21:21:21::/64`** — router **`fd21:21:21::1`**, Knots LXC **`fd21:21:21::21`** (sole service host). bitcoind binds P2P on IPv4 `21.21.21.21` **and** IPv6 `fd21:21:21::21`; **RPC remains IPv4-only** on `21.21.21.21:8332` (never WAN IPv6). WAN IPv6 inbound allow/redirect **TCP 8333 only** to the DMZ node. |
| **N7** | P3 | From **DMZ (`21.21.21.21`) outbound**: **allow any** initially so Knots can peer/sync; **refine** to a tighter allowlist after real runtime observation (document changes in AS_BUILT). |
| **N8** | P3 | From **LAN → DMZ**: port redirect/allow is **restricted to only required ports** — no open DMZ from LAN. Required path: router UI/proxy → **`21.21.21.21:8332`**. |
| **N9** | P3 | **Port roles (locked):** LAN **`443/tcp` TLS** (and **`80`→HTTPS**) = appliance **node web UI** (browser-facing). Knots **JSON-RPC** (**`8332/tcp`** on `21.21.21.21`) = data API. These are **not** the same as browser ports. Optional legacy **`21443`** redirects to the primary HTTPS UI. |
| **N10** | P3 | LAN browsers hit **`https://192.168.1.254/`** (primary). OpenWrt node UI connects to **`21.21.21.21:8332`**. Raw Knots RPC is **not** published to the whole LAN. |
| **N11** | P3 | **UPnP / NAT-PMP off** by default; inbound P2P relies on explicit WAN **8333** DNAT (N6). |
| **N12** | P3 | **SSH:** enabled on **LAN only** for **dev** images; **production** default is SSH off or key-only (TECH_SPEC). Never expose SSH on WAN by default. |
| **N13** | P3 / Phase 2 | TLS for node UI **443** and LuCI **8443**: **self-signed / local CA** for v1 — **same CA leaf** on nginx and uhttpd so one trust covers Node Status **and** Router settings. Server SAN includes LAN IP + `node-router` / `knots-router` / `rnode.local` (mDNS IUE entry — **U17**). **HTTP→HTTPS:** node UI **80→443** and LuCI **8080→8443** (B6, U1, U1a, N9). **Exceptions on HTTP:** (1) CA and install helpers (`/knots-ca.crt`, `/tls/*`) so trust can be installed before the browser trusts HTTPS; (2) **while Setup is incomplete** (`/etc/knots/setup-complete` absent), the **Setup IUE surface** (Setup/reset/upgrade wait pages, `/api/setup`, and required static assets) is served on **HTTP `:80`** so the user can reach the wizard **before** installing the cert — after the HTTPS trust step succeeds, Setup continues on **HTTPS** and `:80` redirects to HTTPS again (except N13 downloads). While Setup is incomplete, **no** `:80` path redirects to HTTPS (strays 302 to `/setup.html`). All HTTP↔HTTPS redirects are **302 + `Cache-Control: no-store` — never 301** (browsers cache 301 permanently and replay it across reflashes/resets into an immediate cert warning before the HTTP IUE — **F135**). **IUE:** Setup (**U17**) puts **HTTPS trust first** after Welcome; after install, Setup **verifies HTTPS** and soft-reloads the page if needed (browsers cannot be force-quit from the page). OS detect shows **only that OS’s** steps + primary download (optional reveal other OS); Windows / macOS / Linux / iOS / Android. Steps must assume **zero computer experience** — including browser download prompts (**Allow** / **Save** / **Keep**, especially **Firefox**), where the file lands, and chmod/`./` on Linux. **Skip for now** allowed (HTTPS may warn until CA installed). `/tls.html` remains the post-Setup help path. |

#### 4.4.1 Network map (locked)

```
Internet
   │
  WAN (DHCP client) ── DNAT tcp/8333 ──► 21.21.21.21:8333   (Knots P2P IPv4)
                 └── DNAT tcp/8333 ──► fd21:21:21::21:8333 (Knots P2P IPv6, N6a)
   │                         │
   │                    DMZ out: allow any (refine later)
   │                    UPnP/NAT-PMP: off
   │
  DMZ link: 21.21.21.1 / fd21:21:21::1 (router)
            ←→ 21.21.21.21/32 + fd21:21:21::21/64 (Knots LXC only)
   │
  LAN 192.168.1.0/24
  gw 192.168.1.254  hostname node-router
  DHCP 192.168.1.100–200
   ├── tcp/80,443     → Knots dashboard (nginx; 80→HTTPS)
   ├── tcp/8080,8443  → LuCI (uhttpd; linked from dashboard)
   └── tcp/21443      → optional redirect → https://192.168.1.254/
                         │
                         └── allow: router → 21.21.21.21:8332  (Knots RPC)
```

**Note on browser UI vs RPC:** `443`/`80` are HTTPS/HTTP for humans; `8332` is Knots RPC for the UI backend. Do not DNAT browser ports onto RPC `8332`.

### 4.5 Wallet, Lightning, privacy (Phase 3 — reserved)

| ID | Phase | Description |
|----|-------|-------------|
| **W1** | P6 / Phase 3 | Support the **default wallet Knots uses**, reachable via LAN web UI, suitable for non-expert users. |
| **W2** | P6 / Phase 3 | Wallet keys remain local to the appliance; no custodial cloud backend. |
| **W3** | P7 / Phase 3 | Architecture allows a **Lightning** wallet/node module without redesigning router/node core. |
| **W4** | P7 / Phase 3 | Architecture allows **plug-and-play integration of existing external wallets** (connect/enable modules rather than forking core). |
| **W5** | Phase 1–2 | Phase 1/2 lines may only add **extension hooks / docs** for Phase 3 — not wallet/LN/privacy product features until Phase 3 is authorized. |
| **W6–W13** | Phase 3 | Backup ack, LAN-only wallet, migration off `disablewallet`, external-app enable path, LN backend/ports — see `docs/PHASE3_REQUIREMENTS.md`. |
| **M1–M7** | Phase 3 / P2B-D | Non-custodial **on-appliance** privacy module (**M-B**); optional; Knots-backed; LAN-only manage — see `docs/PHASE3_REQUIREMENTS.md`. |

---

## 5. Non-functional requirements

| ID | Description | Target |
|----|-------------|--------|
| **NF1** | Skill barrier | Non-technical user can replace a home router and run a full node without CLI. |
| **NF2** | Dual UI | LuCI (router) + Knots/appliance UI (node) both available on LAN. |
| **NF3** | Bring-up | Factory: SD (or equivalent local media) flash from PC is the **install** path. Production runtime: unit boots **eMMC** without SD (**R5**). Dev may boot SD for iteration (**R5a**). |
| **NF4** | Sync path | IBD / tip sync over WAN to upstream network. |
| **NF5** | Production time-to-useful | Factory M.2 preload (P4) preferred over multi-week IBD per unit. |
| **NF6** | Expandability | Phase 3 (P6–P7 / privacy) can land without breaking R*/B*/S* contracts. |
| **NF8** | Phase 2 chain preserve | Deploying Phase 2 system software (SD overlay, sysupgrade, eMMC install) must not delete M.2 `blocks/` / `chainstate/`. No on-device wipe path (**S7**). |
| **NF9** | Phase 2 Settings upgrade | **Settings appliance upgrade (**R14**)** must never format, wipe, re-image, or relocate M.2 chain data (`blocks/`, `chainstate/`). Upgrade changes **system/appliance software only**. Knots/Core binary installs remain under **Node software** (**B19–B21**) and likewise must not wipe chain. |
| **NF10** | Phase 2 retail isolation | Before shipping a sold unit/image: prove **WAN ↛ LAN** (no unsolicited), **DMZ ↛ LAN**, **WAN ↛ management** (UI/SSH/RPC), and **WAN → DMZ only via 8333** using **T5** scripts. Community reviewers may assist; results recorded in AS_BUILT. |
| **NF7** | Reliability | Storage ambiguity fails closed (no surprise mkfs on sealed/prepared disks). |

---

## 6. User experience requirements

| ID | Phase | Description |
|----|-------|-------------|
| **U1** | P3 | **Primary entry:** Knots dashboard on LAN at **`https://192.168.1.254/`** (TCP **443**). **TCP 80** redirects to HTTPS except **N13** trust downloads (`/knots-ca.crt`, `/tls/*`) and the **Setup IUE cleartext surface** while Setup is incomplete (**U17**). Dashboard includes a clear link to **Router settings (LuCI)**. |
| **U1a** | P3 | **LuCI** on LAN at **`https://192.168.1.254:8443/`** (TCP **8443**). **TCP 8080** redirects to **8443** HTTPS. LuCI must expose a **return link/menu entry** to the Knots dashboard (`https://192.168.1.254/`). |
| **U1b** | P3 | Knots / Node Dashboard supports **light** and **dark** themes. **Default follows the desktop/OS colour scheme** (`prefers-color-scheme`); user may override and the choice persists in the browser. |
| **U2** | P3 | Appliance node status UI (primary on **443**): minimum sync %, tip height/hash, peers, uptime, errors, M.2 free-space warning; backed by a simple status JSON API. |
| **U3** | P3 | Clear separation in UX: “Bitcoin node” (Knots dashboard, default) vs “Router settings” (LuCI, secondary). |
| **U7** | P3 / Phase 2 | Node dashboard (or linked page) lets the user select **Bitcoin Core (default, B15)** or **Bitcoin Knots**, shows the active implementation/version, and warns that switching restarts the node (shared datadir; **no chain wipe**). |
| **U7a** | P3 / Phase 2 | **Wallet-aware node switch:** Before changing Knots↔Core, UI must (1) detect if an appliance wallet directory exists on the shared datadir (at least `appliance` and/or `lightning`), (2) show a clear warning that keys are intended to stay on the same disk but switching is **not recommended** when a wallet is present because recovery may require offline backup / descriptor material, (3) require an explicit acknowledgment plus the existing confirm token before apply. Do not imply funds are deleted by a normal switch; do recommend **do not switch with funds** unless backup is verified. Applies in Phase 2 even though wallet UI is deferred (lab leftovers may exist). |
| **U8** | P3 / P5 | **No M.2 wipe product surface.** Do not offer Storage wipe in nav, a wipe page, wipe API, or wipe CLI (**S7**, **D4**). Factory imaging rebuilds chain data off-device (**S5**). |
| **U9** | Phase 2 | **Primary Node Dashboard nav (Phase 2):** **Node Status**, **Node software**, **Settings**, and **Router settings (LuCI)**. Do **not** show Wallet, External apps, Lightning, or Privacy as primary nav items until a **Phase 3–capable image** is installed and Phase 3 is authorized. |
| **U10** | Phase 2 | **Brand header matches active implementation:** primary dashboard title shows **Bitcoin Core** when Core is selected/running and **Bitcoin Knots** when Knots is selected (same source as Node software / `node_impl`). Must update after switch without a full page hard-code of the wrong name. |
| **U11** | Phase 2 | **Node software** page shows installed Knots/Core versions, active impl, and controls to **upload + install** a release tarball for Knots or Core (**B19**, **B21**), plus **rollback** to the previous install when present (**B20**). Confirm token required; if wallet dirs exist, apply **U7a**. LAN only; WAN must not trigger install. **Knots/Core binary updates stay here** — not on Settings appliance upgrade (**R14**). |
| **U12** | Phase 2 | **Settings** page (primary nav): **UI language** (**U19**), appliance software upgrade (**U13**/**R14**), bitcoin.conf management (**U14**/**B22**/**B23**), and **power / node controls** (**U18**). Clear copy that upgrades improve the appliance and **do not wipe the blockchain**. Every mutating control requires **U15** auth. |
| **U13** | Phase 2 | Settings **Upgrade** section: show current **product version** (**R1a**); **LAN upload** of the appliance sysupgrade/image artifact; **required SHA256** text field (paste from the release / checksum page — preferred over uploading a `.sha256` file so the hash comes from a separate trusted channel); confirm phrase; progress/result. Browser and appliance both verify the uploaded bytes match the pasted hash **before** `sysupgrade` begins; mismatch fails closed (no flash). Intended contents of upgrades: **new functionality** (including shipping a Phase 3 feature image when released) and/or **high-severity bug fixes**. Refuse WAN-triggered upgrade. Obey **NF9**. |
| **U14** | Phase 2 | Settings **Bitcoin config** section: **safe form** (allowlisted keys) plus optional **Advanced raw editor** behind extra confirm (**B23**). On save: require auth (**U15**), validate, write conf, then **restart bitcoind** with an explicit “node will restart” confirm. Show success/failure; do not leave the node stopped without an error surface. |
| **U15** | Phase 2 | **Settings auth:** Every **mutating** Settings action (UI language change, appliance upgrade apply, conf save/restart, node stop/start, device reboot/shutdown, and any future Settings write) requires the operator to enter the **router admin username and password** (same credentials as LuCI/`root`, **R13**) on that action — no Settings write without password. LAN only; WAN must not accept these mutations. Read-only display of version/conf may remain visible without re-auth. |
| **U16** | Phase 2 | **Reindex recovery UX (Node Status):** When **B24** is detected, Node Status must show a clear recovery panel/modal (not only a raw RPC error) that: (1) states the node cannot start until the chain database is repaired; (2) states this is **validation / rebuild of chainstate from blocks already on the M.2** — **not** downloading the blockchain again; (3) warns it can take many hours and power must stay on; (4) requires confirm token **`REINDEX`** before starting. While reindex runs, Status shows an honest progress/maintenance state (reuse busy/initialising patterns). LAN only. |
| **U17** | Phase 2 | **First-run Setup wizard (retail):** One-time wizard before Node Status (LAN cable or factory Wi‑Fi **`rnode` / `knotsnode21`**). **Audience:** assume **zero computer experience** — every step explains what to tap, which dialogs may appear, and what success looks like (`docs/FIRST_RUN_UX.md`). **Look and feel:** same appliance chrome as Node Status — shared brand header / shell, **light/dark** theme (**U1b**), typography, colours, buttons, and form controls from the Knots UI (`shell.js` / `theme.js` / `app.css`); must **not** look like LuCI or a separate skin. **Entry:** user joins **`rnode` / `knotsnode21`** or uses a LAN cable, then opens **`http://rnode.local/`** (mDNS + router DNS record; the LAN IP `http://192.168.1.254/` also works) — Setup runs on **HTTP** until the Security step succeeds, then continues on **HTTPS** (**N13**). **Flow (IUE v2, 2026-09):** **Page 1 Welcome** — “Welcome to RNode and the Bitcoin Ecosystem.” + Continue → **Page 2 Security** (HTTP) — one **Secure My Connection** button downloads a per-OS trust installer; the visitor runs it (the OS itself prompts for the computer password — never collected by the page); the page shows **live progress** and switches to **HTTPS** automatically once the trust probe succeeds; Skip allowed; step-by-step per-OS help remains as fallback (**N13**) → **Page 3 Setup** (HTTPS) with two paths: **Quick Start** (recommended for non-technical people — factory defaults: node **Core** (**B15**), SSID **`rnode`** (**U6**), WAN DHCP auto with ISP/PPPoE popup on failure (**R10a**), browser-detected locale (**U19**); the user only sets router password (**R13**) + Wi‑Fi password) or **Guided Setup** (recommended for technical people — Node Core/Knots → WAN (DHCP then PPPoE) → optional LAN IP range → Wi‑Fi SSID/password → router password); browser-detected locale is shown for confirmation/change on the Setup page. **Staged Finish (Windows and Linux):** Quick Start and Guided **must not** apply client-dropping network changes (LAN IP, Wi‑Fi SSID/PSK) until the **final** Finish step. The factory LAN address and factory AP stay up through the wizard. Finish is **one** cutover: commit staged UCI, keep the previous LAN IP as a short-lived alias if the range changed (reissue the HTTPS leaf with **both** IPs + `rnode.local`, same CA — no reinstall), deauth Wi‑Fi stations or reload radios only as needed, then **one** wait page that probes **`rnode.local`** (never `https://<lan-ip>/`) for ~3 minutes with copy to join the chosen SSID and to toggle Wi‑Fi or reseat a cable if the IP range changed. **WAN DHCP/PPPoE** may apply when chosen so the internet check is real (**R10a**) — that does not drop the Setup client. Admin password and locale apply when chosen (must not store the new password in a staging file). **Done** → Node Status (**HTTPS**). Reuse OpenWrt `passwd` / `netifd` / UCI `network`+`wireless` / `system` timezone — no parallel stack. No stock LuCI package provides this exact flow; LuCI remains escape hatch. Normative playthrough: `docs/FIRST_RUN_UX.md`. |
| **U19** | Phase 2 | **Language & timezone (IUE / worldwide):** Setup collects (1) **UI language** for the Knots node site **and** LuCI (`luci.main.lang`), and (2) **timezone** (IANA/OpenWrt **zonename**, e.g. `Australia/Sydney`) that **sets the router clock** via UCI `system.@system[0].zonename` + `.timezone` and `/etc/localtime` (zoneinfo). The timezone catalog entry also supplies the default **Wi‑Fi regulatory country** when a radio is present. Persist Knots UI language under `/etc/knots/ui-lang` (and apply on every Knots page via shared i18n). Shipped languages (v1): English plus at least Spanish, German, French, Simplified Chinese, Japanese, Brazilian Portuguese (additional languages may be added without changing this ID). Timezone list is a curated worldwide catalog (IANA zonename + POSIX TZ + ISO country for Wi‑Fi). **Since IUE v2 (2026-09):** Setup may **auto-detect language & timezone from the browser** (IANA `Intl` timezone + `navigator.language`) and apply silently with a confirmation/change affordance — an explicit locale step is then optional, not mandatory. **After Setup:** Settings (**U12**) must let the operator change **UI language** again; applying it updates **both** the Knots Node UI **and** LuCI, with **U15** auth. Timezone remains Setup (or a later Settings timezone control); language is not locked forever after first run. |
| **U18** | Phase 2 | **Settings power / node controls:** From Settings, LAN-authenticated operator may (1) **stop** the Bitcoin node (`bitcoind`), (2) **start** the node, (3) **reboot** the appliance, (4) **shutdown** (power off) the appliance. Each action requires **U15** auth plus confirm tokens **`STOP`** / **`START`** / **`REBOOT`** / **`SHUTDOWN`**. **Start** is available only when the node is **stopped**; the Start control is disabled while running, and `node_start` is refused (`already_running`) if `bitcoind` is alive — stop first, then start (including ReIndex). **Start** may include optional **ReIndex Node**: checkbox on; dropdown appears only when checked; default **Repair chain database** (`-reindex-chainstate`); optional **Also rebuild the block index** (`-reindex`). Each reindex choice shows a warning popup that states the action (not a re-download; hours; keep power on). On Settings load, if any `-reindex` / `-reindex-chainstate` is already running, the ReIndex checkbox is disabled and Settings shows **Reindex in progress**. Reboot and shutdown **must stop the node first** (graceful flush) before the OS reboot/poweroff. **LuCI System → Reboot** (and any clean `reboot` / `poweroff` from the host) **must also stop the node first** — same stop path as Settings; do not leave `bitcoind` running across a software reboot. Hard power-loss cannot be graceful; next boot recovers via journal + chainstate verify and auto-starts the node. Never wipe M.2. |
| **U4** | P6 / Phase 3 | (Reserved) Wallet UI follows Knots default wallet model. |
| **U5** | P7 / Phase 3 | (Reserved) External wallet / Lightning / Privacy modules as optional plug-ins. |
| **U6** | Phase 2 | Default Wi‑Fi SSID **`rnode`** when hardware is present (**R7**, **U17**); factory PSK **`knotsnode21`** until Setup. User may change SSID in Setup. New Wi‑Fi password required in Setup (min **8** chars; not the factory PSK). |

---

## 7. Build & delivery requirements

| ID | Phase | Description |
|----|-------|-------------|
| **D1** | P1 | Reproducible image build via Makefile / Image Builder documented in repo. |
| **D2** | P1 | `files/` overlay carries first-boot, storage helpers, and UI/firewall assets. |
| **D3** | P4 | Factory tooling can capture/flash M.2 data images separately from the system image. |
| **D4** | P5 | Must **not** ship on-device storage wipe CLI or `storage.html` / wipe CGI (**S7**, **U8**). M.2 chain rebuild is **factory imaging** only (**D3**, **S5**). Empty-disk **prepare** (**S2**) remains for blank media at first boot. |

---

## 8. Testing requirements

| ID | Description |
|----|-------------|
| **T1** | Tests look for bugs and use **real data** / real devices when exercising storage and sync paths. |
| **T2** | On any failure: stop, find **root cause**, fix, restart tests from the beginning until 100% pass. |
| **T3** | Storage negatives required: empty disk prepare; prepared/factory mount-only; **assert wipe tools/UI absent** (no `storage-wipe.sh`, no wipe CLI, no Storage nav/page) per **S7**/**U8**/**D4**. |
| **T4** | LAN access checks: LuCI reachable; Knots/appliance UI reachable; WAN management denied in production defaults. |
| **T5** | **Zone isolation / stress (Phase 2 retail):** From **LAN**, **Wi‑Fi (LAN)**, **WAN**, and **DMZ**, run the documented probe scripts (`tests/security/`, **DOC4**). Pass = management/UI/SSH/RPC closed from WAN; **DMZ cannot reach LAN**; WAN→DMZ only **8333**; LAN UI reachable as designed. Fail closed — ship blocked until 100% pass (**T2**). |

---

## 9. Documentation requirements

| ID | Description |
|----|-------------|
| **DOC1** | `docs/AS_BUILT.md` updated for every completed layer and fix (Symptom / Root cause / Fix). |
| **DOC2** | Open unknowns go to `docs/SCOPE_GAPS_REPORT.md` — do not invent closures. |
| **DOC3** | User-facing bring-up (production): power on **eMMC-booted** unit, insert/prepare M.2 as shipped, cable WAN, then join **`rnode` / `knotsnode21`** or use a LAN cable, open **`http://rnode.local/`**. Do not instruct end users to keep a system SD card. |
| **DOC3a** | Factory bring-up: document SD → SPI-NAND (as required by OpenWrt BPI-R4 flow) → **eMMC** install, boot-select, SD removal, and verification that the appliance runs from eMMC (**R5**/**R5a**). |
| **DOC4** | Zone security test guide: `docs/SECURITY_ZONE_TEST.md` — how reviewers/operators run LAN / Wi‑Fi / WAN / DMZ probes (**T5**, **NF10**). |

---

## 10. Explicit non-goals (current)

- Competing with Umbrel/Start9 app-store breadth in Phase 1–2.
- Shipping Phase 3 wallet / Lightning / external / privacy **product tabs** while Phase 2 is the authorized deploy target.
- Enabling Wi‑Fi in builds before hardware is available (config defaults still reserve SSID `rnode`).
- Using `bitcoin-qt` as the appliance UI.
- Making expert recovery (serial console) the primary supported path for end users.
- Wiping M.2 chain data as part of a normal Phase 2 deploy or eMMC install.

---

## 11. Locked decisions (was open)

| Topic | Lock |
|-------|------|
| Node mode | **Unpruned full node** (B1) |
| LAN | **`192.168.1.0/24`**, gateway **`192.168.1.254`** (R6, U1) |
| Node DMZ | Link `21.21.21.0/24`; sole host **`21.21.21.21`**; router link **`21.21.21.1`** (R8, N1) |
| Containment | **LXC** + `bitcoind`; **`disablewallet=1`** for Phase 2 (B8, B9); Phase 3 may enable wallet |
| Product phases | **Phase 1** = BB1 freeze; **Phase 2** = Node SKU (current); **Phase 3** = wallet/LN/external/privacy |
| Peers | **Clearnet** v1; Tor/I2P not required (B3) |
| WAN | DHCP client by default; Setup DHCP-first then PPPoE (**R10**, **R10a**); **DNAT 8333** IPv4+IPv6 (**N6**, **N6a**); **UPnP off** (N11) |
| LAN | DHCP **`.100–.200`**; hostname **`node-router`**; Knots UI **80/443**; LuCI **8080/8443** (R9, R11, B6, U1/U1a) |
| Knots pin | **`v29.3.knots20260507`** non-RDTS (B4a) — bundled Knots build; **default node is Core** (**B15**); user may install other released versions (**B19–B21**, **U11**) |
| Core pin | **`v29.5`** shipped default implementation (B15–B17); user may install other released versions (**B19–B21**, **U11**) |
| Node binaries | M.2 `/mnt/bitcoin/node-bin/{knots,core}/` with `.prev` rollback (B19, B20) |
| Node datadir | Shared `/mnt/bitcoin` for Knots and Core (B17) |
| LAN → DMZ | Required only: router → RPC **8332** (N8–N10) |
| DMZ outbound | **Allow any** first; refine later (N7) |
| Bring-up | **Production: eMMC boot**; SD = factory/dev install only (R5, R5a) |
| SPI-NAND | Bootloader / recovery bridge only — not full appliance root (R5) |
| Product version | **`{openwrt}.{core}.{build}`** e.g. `24.10.8.29.5.119` (R1a) |
| Port map | **Stock OpenWrt BPI-R4** defaults (R12) |
| Admin password | Lab **`knotsnode21`**; retail Setup **must** change (**R13**, **U17**) |
| TLS v1 | Local CA + **Setup HTTPS trust step** + install scripts (**N13**, **U17**); `/tls.html` help |
| Factory reset | System config reset; **never** wipe M.2 (**N3**, **S7**) |
| M.2 wipe | **Not shipped** — factory pre-image only (**S5**, **S7**, **U8**, **D4**) |
| M.2 | **1 TB**; fail closed if missing; low-space UI warn (B5, B13, B14) |
| Wi‑Fi | Factory AP **`rnode` / `knotsnode21`**; Setup SSID **`rnode`** (editable) + new password (8–63, not factory) when radio present (**R7**, **U6**, **U17**, **R13**); IUE on Wi‑Fi or LAN cable |
| First-run Setup | Open **`http://rnode.local/`** → **Welcome** → **Security** (cert install → HTTPS) → **Quick Start** or **Guided Setup** (LAN/Wi‑Fi staged until **one** Finish cutover) → Status (**HTTPS**) (**U17**, **U19**, **U1b**, **N13**; `docs/FIRST_RUN_UX.md`) |
| Language / timezone | Setup **U19**: Knots UI + LuCI language; OpenWrt **router timezone** (zonename + `/etc/localtime`) + Wi‑Fi country from catalog. Settings: change language (Knots + LuCI) with **U15** |
| Wallet / LN / privacy UX | **Phase 3** only (nav appears when a Phase 3–capable image is installed and authorized; Phase 2 hides those tabs — **U9**) |
| Settings nav | **Settings** primary tab (**U12**); language (**U19**) + upgrade + bitcoin.conf + power/node (**U18**) |
| Appliance upgrade | **LAN upload** sysupgrade-class image + **required SHA256 paste** (**R14**, **U13**); never wipe chain (**NF9**) |
| Upgrade intent | New functionality (incl. future Phase 3 image) and/or high-severity bug fixes |
| Knots/Core binaries | Remain on **Node software** (**U11**, **B19–B21**) — not Settings upgrade |
| bitcoin.conf UI | Safe allowlisted form + Advanced raw editor (**B22**, **B23**, **U14**); save restarts node |
| Settings auth | Per mutating action: router username + password (**U15**, **R13**); LAN only |
| Chain DB recovery | Detect needs `-reindex-chainstate`; Node Status modal (**B24**, **U16**); Settings Start optional full `-reindex` (**U18**); not a re-download |
| Retail isolation | Zone probes LAN/Wi‑Fi/WAN/DMZ before ship (**T5**, **NF10**; `docs/SECURITY_ZONE_TEST.md`) |

### 11.1 Still open (must not be invented in code)

Full register: `docs/SCOPE_GAPS_REPORT.md`. Remaining highlights:

1. Concrete **`{openwrt}.{core}.{build}`** string per release build (R1a).
2. Factory DOC3a eMMC install SOP verification on hardware (R5a).
3. Deferred: refined DMZ egress (**G5**); Wi‑Fi multi-radio polish in TECH_SPEC §7.6.
4. **First-run Setup implement detail (TECH_SPEC §7.6):** timeouts, password min length, setup-complete marker, lab skip policy — do not invent in UI without TECH_SPEC.
5. **Phase 3** product modules remain gated until owner authorizes; may ship later **via Settings appliance upgrade** (**R14**) without wiping chain (**NF9**).
---

## 12. Requirement ID index

| Prefix | Meaning |
|--------|---------|
| **R*** | Router / OpenWrt / LuCI |
| **B*** | Bitcoin Knots node |
| **S*** | M.2 storage |
| **N*** | Network security / ops signals |
| **W*** / **M*** | Wallet / Lightning / external / privacy (**Phase 3**) |
| **NF*** | Non-functional |
| **U*** | User experience |
| **D*** | Build & delivery |
| **T*** | Testing |
| **DOC*** | Documentation |

---

## 13. Acceptance summary (product)

### Phase 2 (current) success bar

A non-technical user (or lab acceptance) can:

1. Run a unit that **boots from eMMC** (no system microSD required) as home router — **Node dashboard** on **80/443** at `192.168.1.254`; LuCI on **8080/8443** with mutual links; DHCP `.100–.200` (**R5**).
2. Have **1 TB** M.2 prepared or factory-preloaded automatically (fail closed if missing); **Phase 2 deploy/sysupgrade/eMMC install does not wipe chain** (**NF8**, **S3**).
3. Run unpruned **Bitcoin Core** (default — **B15**) or bundled Knots **`v29.3.knots20260507`** (**B4a**) in **LXC** at **`21.21.21.21/32`**, WAN **8333** DNAT in, UPnP off; switch Knots/Core (**B15–B18**, **U7**/**U7a**) without chain wipe.
4. On **Node software**, install/replace Knots or Core from an official aarch64 tarball (LAN upload) and roll back to the previous install when present (**B19–B21**, **U11**) without wiping chain.
5. See primary nav: **Node Status**, **Node software**, **Settings**, **Router settings** (**U9**/**U12**) — no Wallet / External / Lightning / Privacy tabs until Phase 3–capable image + authorization.
6. On **Settings**, LAN-upload an appliance upgrade without touching the chain (**R14**, **U13**, **NF9**); edit bitcoin.conf (safe form + advanced) with router username/password per save and restart the node (**U14**, **U15**, **B22**, **B23**); stop/start the node and reboot/shutdown the device with auth (**U18**).
7. Rebooting from **LuCI** (or any clean host `reboot`/`poweroff`) stops the Bitcoin node first (**U18**).
8. On **retail** first power-on, join **`rnode` / `knotsnode21`** (or use a LAN cable), open **`http://rnode.local/`**, and complete **Setup** (**U17**): **Welcome** → **Security** trust step (or skip) → **Quick Start** or **Guided Setup** (LAN IP and Wi‑Fi staged until Finish; one cutover) — then Node Status on **HTTPS**.
9. Factory can produce that eMMC system via SD→(SPI-NAND)→eMMC (**R5a**, **DOC3a**). Dev SD boot remains allowed for iteration.

**Primary success bar:** Phase 2 Node SKU on **eMMC**, chain intact. **Phase 3** wallet/Lightning/external/privacy come after owner authorization (may be delivered later as an appliance upgrade image).