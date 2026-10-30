# Product Phase 3 — Wallet / Lightning / external / privacy

**Status:** LOCKED (requirements) — **implement only when owner authorizes Phase 3**  
**Date:** 2026-08-12 (renamed from historical “Phase 2 Build”; content locked 2026-08-08)  
**Prerequisites:** Product Phase 2 Node SKU (`docs/PHASE2_NODE_SKU.md`); Phase 1 BB1 remains recovery baseline  
**Parent authority:** `REQUIREMENTS.md` (amend both on conflict)

**Naming note:** This document was formerly `docs/PHASE2_REQUIREMENTS.md` (“Phase 2 Build”).  
**Product Phase 2** is now the Node SKU (no custody tabs). **Product Phase 3** reinstates the modules below.  
Stage IDs **P2B-A/B/C/D** are retained for continuity with AS_BUILT decisions D25–D28.

---

## 1. Goal

After Phase 2 (router + unpruned node + Knots↔Core switch + status UI), Phase 3 adds **self-custody payment capability** for non-experts:

1. Knots **default wallet** on the appliance LAN UI  
2. **External wallet apps** that can use this node simply  
3. Optional **Lightning** module  
4. Optional **privacy payments** (send/receive mixing) — scoped below  

Still **forbidden:** custodial / cloud key custody (REQUIREMENTS §3.3).

---

## 2. Stages (implementation order)

| Stage | Maps to | Scope | Implementation gate |
|-------|---------|-------|---------------------|
| **P2B-A** | P6 / W1–W2 / U4 | Knots default wallet on LAN UI | Owner says “implement Phase 3 / P2B-A” |
| **P2B-B** | P7 / W4 / U5 | Plug-and-play external wallet docs + RPC access pattern | After P2B-A green **or** parallel if owner allows |
| **P2B-C** | P7 / W3 / U5 | Lightning module (architecture + optional ship) | After node+wallet threat model reviewed |
| **P2B-D** | **M1–M7** (mode **M-B**) | On-appliance privacy module | After P2B-A threat/backup solid; never blocks A–C |

Phase 1/2 contracts (storage, DMZ, LuCI, status UI, Knots↔Core) remain mandatory through all stages.

---

## 3. P2B-A — Knots default wallet (LOCKED)

| ID | Requirement |
|----|-------------|
| **W1** | Expose the **default wallet Knots uses** via the LAN appliance UI. Non-expert usable. |
| **W2** | Keys remain **local** on the appliance; no custodial cloud backend. |
| **W6** | Before first spend: user must complete a **backup / recovery acknowledgment** (seed or Knots-equivalent backup UX). Exact UX in TECH_SPEC when implementing. |
| **W7** | Wallet features stay **LAN-only**; WAN must not expose wallet RPC or wallet UI by default. |
| **W8** | Shipping P2B-A means flipping off Phase 2’s `disablewallet=1` under a controlled migration (documented); IBD/datadir must not be wiped. |
| **U4** | Clear UX: “Bitcoin wallet” vs “Router settings” (LuCI) vs “Node status”. |

**Out of P2B-A:** multisig vault product, hardware-signer factory integration, Lightning.

**Open for TECH_SPEC at implement time (not blocking lock):** exact backup wording, PIN/password beyond `root`, coin control depth.

---

## 4. P2B-B — External wallet apps (LOCKED)

| ID | Requirement |
|----|-------------|
| **W4** | Support **plug-and-play** use of existing external wallets against this node (connect/enable — not fork core). |
| **W9** | Publish a **supported apps list** (docs) with connection method (e.g. LAN RPC over TLS tunnel, or limited cookie/user auth pattern). Initial targets to evaluate at implement time: **Sparrow**, **Specter**, **BlueWallet** (watch-only / node connect where applicable). Final list recorded in AS_BUILT. |
| **W10** | Default posture: raw Knots RPC is **not** open to the whole LAN. External apps get an **explicit enable** path (token/user, bind allowlist, or SSH tunnel doc). |
| **U5** | External wallet path is optional; appliance remains useful with node-only or Knots-wallet-only. |

**Out of P2B-B:** shipping third-party wallet binaries inside the image as the primary UX.

---

## 5. P2B-C — Lightning (LOCKED as module; ship optional)

| ID | Requirement |
|----|-------------|
| **W3** | Architecture allows a **Lightning** wallet/node module without redesigning router/node core (separate process/container, LAN UI module). |
| **W11** | Lightning implementation choice is locked at implement kickoff in AS_BUILT (candidates to evaluate: **CLN**, **LND**, **Eclair** — pick one primary). |
| **W12** | Lightning uses this appliance’s Knots node as the chain backend (no trusted third-party chain source of truth). |
| **W13** | Lightning ports/UI follow same trust model: **LAN-only** management by default; WAN exposure rejected unless explicitly documented later. |

**Out of P2B-C v1:** LSP marketplace product, hosted channels, custodial LN.

---

## 6. P2B-D — Privacy payments / on-appliance mixing (LOCKED — mode **M-B**)

**Owner lock (2026-08-08):** Mode **M-B** — on-appliance privacy module (self-sovereign stack: keys + Knots + privacy tooling on the appliance).

### Locked intent

| ID | Requirement |
|----|-------------|
| **M1** | Phase 3 includes **privacy-preserving send/receive** aids for non-experts, consistent with non-custodial local keys (W2). |
| **M2** | No custodial mixer service; no cloud custody of user funds. |
| **M3** | Privacy features must not replace Knots validation or require a trusted HTTP indexer as chain source of truth. |
| **M4** | Privacy features are **optional modules** — Phase 2 node path must work with privacy features disabled. |
| **M5** | **Mode M-B:** Run a local privacy tool (JoinMarket-class or equivalent evaluated at implement) in **LXC/module** on the appliance, with LAN UI enable/disable. |
| **M6** | Privacy module uses this appliance’s Knots node as chain backend; management **LAN-only** by default (same trust posture as wallet/LN). |
| **M7** | Implementation pick (exact software + maker vs taker default UX) is recorded in AS_BUILT at P2B-D kickoff; threat/backup model must be reviewed before ship (extends G6). |

### Rejected for this product track

| Option | Status |
|--------|--------|
| **M-A** (client-side only) | Not primary — may still appear as optional docs later, not the Phase 3 privacy product |
| **M-C** (defer entirely) | Rejected — P2B-D remains in Phase 3 roadmap after A/B/C gates |

**Implement order:** Do **not** start P2B-D code until P2B-A (wallet backup/threat) is solid enough that hot keys on-appliance are an accepted risk.

---

## 7. Non-goals (Phase 3)

- Custodial or hosted wallets  
- Replacing Phase 1/2 router/node contracts  
- Shipping wallet/LN before Phase 2 Node SKU remains the recovery image  
- Silent enable of prune to “make room” for wallet indexes  

---

## 8. Success bar (Phase 3)

| Stage | Done when |
|-------|-----------|
| P2B-A | Non-expert can receive/send on LAN wallet UI; backup ack enforced; WAN wallet closed |
| P2B-B | At least one external app documented + tested against appliance enable path |
| P2B-C | LN module starts against local Knots; LAN manage; AS_BUILT names implementation |
| P2B-D | **M-B** on-appliance privacy module: documented send/receive privacy path on LAN; optional; Knots-backed; AS_BUILT names software |

---

## 9. Amendment rule

Change Phase 3 product intent by editing this file **and** the corresponding rows in `REQUIREMENTS.md`, then log the decision in `docs/AS_BUILT.md`.
