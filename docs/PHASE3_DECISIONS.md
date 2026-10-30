# Phase 3 decisions (2026-10-18)

Owner decisions for the next product phase, agreed in conversation. They
replace the deferred "locked" items in `PHASE3_REQUIREMENTS.md` where they
differ; the full requirements + threat model are written from this list.

## Product

| # | Decision | Notes |
|---|---|---|
| P3-D1 | **Hardware: Banana Pi BPI-R4 Pro, 8 GB RAM, 2 TB M.2** | New board: OpenWrt support, flash layout, ports, LEDs, Wi‑Fi and factory tools must be ported and verified first (spike S0). |
| P3-D2 | **Customer unchanged** — non-technical; the full suite of services | Every feature needs the same "zero experience" UX bar as Setup. |
| P3-D3 | **Send and receive BTC on-chain and over Lightning** | Core user capability of Phase 3. |
| P3-D4 | **Plain BPI-R4 moves to maintenance** — new sales Pro only; node-only = Pro with wallet features off; plain-R4 units get **12 months** of fixes on `release/2.x` after the Pro ships | One platform going forward. |

## Wallet and Lightning

| # | Decision | Notes |
|---|---|---|
| P3-D5 | **Two-tier wallet** — spending wallet on the router (Lightning + modest on-chain; wallet PIN; per-device app access) + optional savings vault (watch-only on the router, hardware-wallet signing) | Recovery phrase shown at wallet setup with a check; automatic encrypted backups (wallet + channel state) to USB. Spending keys are on an internet-facing router → threat model drives the controls. |
| P3-D6 | **On-chain backend: node's own descriptor wallet**; external wallets connect via an **Electrum-protocol server (electrs)**, Core RPC for Sparrow, and compact block filters | Hardware wallets sign on the user's own device, not via USB on the router. |
| P3-D7 | **Lightning: LND**, confirmed by measuring on the R4 Pro (CLN only if LND proves too heavy) | |
| P3-D8 | **Inbound liquidity: third-party LSP over open standards (LSPS1 / LSPS2)** — default partner chosen by the owner, user can switch | No own LSP for now. |

## Mobile and remote access

| # | Decision | Notes |
|---|---|---|
| P3-D9 | **Remote access: WireGuard direct + automatic Tor fallback** (works behind CGNAT); own relay considered later | Wallet / Lightning ports never reachable from the internet except through these paths. |
| P3-D10 | **Phase 3 ships with existing apps** (Zeus; Electrum-protocol wallets) paired by QR — VPN config + scoped, revocable per-device credential; **own RNode app in Phase 3.1** on the same router API gateway | The router exposes one hardened API gateway, never raw node / LND ports. |

## Mining

| # | Decision | Notes |
|---|---|---|
| P3-D11 | **Router as the miners' pool gateway + solo mode** — any LAN miner (incl. Stratum V1 / Bitaxe) points at the router; the router builds templates from its own node (Stratum V2 Job Declaration) and mines for a user-chosen SV2 pool, or solo; Template Provider also exposed on the LAN for advanced miners | Spike must verify Core's mining interface (and Knots parity), SV2 software on aarch64, pool support. |
| P3-D12 | **Scale: home / small** — a handful to a few dozen devices on the LAN | Mining services LAN-only. |

## Privacy

| # | Decision | Notes |
|---|---|---|
| P3-D13 | **Privacy by default, no on-box mixing** — Tor for broadcast/P2P, no address reuse, coin control + labels, Lightning for daily spend; **PayJoin** a later candidate | Drops the old JoinMarket-class requirement (M-B): legal exposure, UX, resources. |

## Engineering

| # | Decision | Notes |
|---|---|---|
| P3-D14 | **One repository, two branches** — `release/2.x` (node product, fixes only) and `main` (Phase 3); releases tagged (`v2.0.0-rc1` = build .96) | |
| P3-D15 | **Hosting: private GitHub** | Repository never contains secret keys. |
| P3-D16 | **Signed releases from the first Phase 3 build** — release key A (signing) + key B (backup), generated offline from a live USB on a laptop with no network, each on its own encrypted USB | Done 2026-10-21, regenerated 2026-10-27 (sticks' passphrases lost before any release): A `2e51b93dd6058ffb`, B `833eb2b299741478`; test builds use a separate TEST key (`keys/README.md`). |
| P3-D17 | **Separate containers** for wallet + LND, Electrum server, mining, API gateway; least-privilege networking between them | |

## Storage resilience (proposed, awaiting owner)

Options and evidence: `docs/PHASE3_STORAGE_RESILIENCE.md`.

| # | Question | Recommendation |
|---|---|---|
| P3-D18 | Storage hardware | Split: 2 TB TLC for blocks + 480 GB PLP drive for chainstate / wallets / LND |
| P3-D19 | Lightning state protection | Event-driven encrypted SCB + wallet backups (eMMC, USB, opt-in off-box) **and** an NVMe mirror of LND / wallets |
| P3-D20 | Off-box encrypted backup | Yes, opt-in |
| P3-D21 | UPS | One supported model with clean-shutdown signalling |
| P3-D22 | Drive health monitoring on `release/2.x` | Yes (nvme-cli collector) |
| P3-D23 | Phase 2 retail drive size | 2 TB (1 TB is nearly full) |

## Next steps

1. Push the repository to private GitHub; create `release/2.x`; tag `v2.0.0-rc1`.
2. Phase 3 requirements + threat model document from this list, for review.
3. Spike S0: Phase 2 firmware on the BPI-R4 Pro (needs a board).
4. Spikes S1–S3 on the Pro: electrs + LND resource budget; Stratum V2 template provider / Job Declaration with the pinned Core (and Knots); WireGuard + Tor pairing.
5. ~~Release keys A/B (owner, offline)~~ — done 2026-10-21.
6. Owner decisions P3-D18…D23; storage spikes S4–S8 (see the storage resilience doc).
