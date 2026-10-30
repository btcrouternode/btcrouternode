# Product Phase 2 — Node SKU

**Status:** AUTHORIZED (current deploy target)  
**Date:** 2026-08-12  
**Parent authority:** `REQUIREMENTS.md` §2.1  
**Prerequisite:** Phase 1 / Baseline Build 1 (`docs/BASELINE_BUILD_1.md`)

## Goal

Ship a stable **router + full node** appliance with:

- OpenWrt + LuCI  
- Unpruned Knots (default) with optional **Bitcoin Core** switch (shared datadir)  
- User **install/replace/rollback** of Knots or Core binaries from official aarch64 tarballs (**B19–B21**, **U11**)  
- Node status UI on LAN **80/443**  
- Production path: system on **eMMC**; M.2 holds chain only  

**Explicitly not in Phase 2 product UX:** Wallet, External apps, Lightning, Privacy tabs (and their enabled runtimes). Those return in **Phase 3** (`docs/PHASE3_REQUIREMENTS.md`).

## In scope

| Area | IDs / notes |
|------|-------------|
| Router / eMMC | R*, **R5**/**R5a** |
| Node + switch | B1–B18, **U7**/**U7a**, **B9** `disablewallet=1` |
| Node versions | **B19–B21**, **U11** — LAN upload install + `.prev` rollback on M.2 `node-bin/` |
| Storage | S1–S7 (S8/S9 retired — no on-device wipe, F86); **NF8** chain preserve on deploy/sysupgrade/eMMC |
| UI nav | **U9**/**U12** — Node Status, Node software, **Settings**, Router settings |
| Settings | **R14**, **U13–U15**, **B22**/**B23**, **NF9** — appliance LAN upgrade (no chain wipe); bitcoin.conf safe+advanced with per-action auth |
| First-run Setup | **U17**, **R7**, **R10a**, **R13** — retail wizard; playthrough `docs/FIRST_RUN_UX.md` — **implemented** (G39 closed 2026-08-14: `setup.html` + `/api/setup`, `docs/FIX_U17_FIRST_RUN_SETUP.md`) |
| Network | N*, U1–U3, U1a, U1b, U8 |

## Out of scope (until Phase 3)

- Primary nav / product enable for Wallet, External apps, Lightning, Privacy  
- Shipping `disablewallet=0` as the Phase 2 default  
- Wiping M.2 `blocks/` / `chainstate/` during Phase 2 deploy or eMMC install  

## Deploy contract

1. Overlay push / sysupgrade / SD→eMMC install updates **system** only.  
2. `/mnt/bitcoin` mount-only when valid FS / markers present (**S3**).  
3. Do not delete chain data; do not require wipe to enter Phase 2.  
4. Stop/disable Phase 3 module runtimes (CLN, privacy enable, LAN external RPC) for Phase 2 posture.

## Success bar

See `REQUIREMENTS.md` §13 Phase 2.
