# Phase 3 storage resilience — options and recommendation (2026-10-19)

Closes the four M.2 design needs raised in the Phase 3 review:

1. Automatic wallet and channel backups **off** the M.2
2. A drive setup that survives sudden power loss
3. Drive health monitoring with early warning in the UI
4. A guided "replace drive" flow

This is based on three research passes (LND/wallet backups, M.2 hardware and
power loss, monitoring/replacement/chain recovery). Each passed on its sources'
confidence: **verified** means read from the primary source or code;
**estimate** means judgment that a spike must confirm.

---

## 0. Starting point

### What is on the drive today (test unit, measured 2026-10-19)

| | |
|---|---|
| Drive | Kingston NV2 1 TB (`SNV2S1000G`), a budget DRAM-less drive |
| Used | **835.5 GB of 915.8 GB — 96 % full, 33.7 GB free** |
| `blocks/` | 824.7 GB (`blk*.dat` 723.7 GB + `rev*.dat` 101.0 GB) |
| `chainstate/` | 10.6 GB |
| Everything else | < 0.2 GB (node binaries, Tor, config) |
| Config | `prune=0`, `txindex=0`, `dbcache=1024` |

Only bitcoind uses the drive in Phase 2. A dead drive costs a full re-sync,
but no funds are at risk: there is no wallet. Phase 3 changes that. LND
channel state and the spending wallet would live on the drive, so a drive
failure or power cut can **lose money**.

> **Phase 2 finding:** a 1 TB drive is nearly full now. At the current
> growth rate of about 6–9 GB a month (estimate), the test unit fills in
> roughly **4–5 months**. The node then stops. The UI already warns below
> 100 GiB free (`status-api.sh` `low_space`). This is recorded as a Retail
> gate in `RELEASE_READINESS.md`.

### Hardware facts that shape the design (BPI-R4 Pro)

- **Two M.2 M-key slots**, 2280, each **PCIe 3.0 x1** (about 1 GB/s), both on
  the **underside** of the board. A fast Gen4 drive gains nothing. Choose
  drives for low power, low heat, endurance and power-loss behaviour.
- **8 GB eMMC** for the system. It is too small for chain data, but fine
  for small backups.
- **Power input 9–24 V DC**, measured about 9–15 W. There is no official UPS.
- There is **no official OpenWrt image for the Pro yet**: kmods (including
  `kmod-nvme`) come from our own build. Spike S0 must cover this.
- The second slot makes two designs possible: **split storage** and
  **migrate-to-slot-2**.

### Capacity projection for a 2 TB drive (estimate)

| Item | Day one | Growth / year |
|---|---|---|
| Blocks + undo | ~830 GB | ~80–110 GB |
| Chainstate | ~11 GB | ~1 GB |
| electrs index (P3-D6) | ~50–70 GB | ~5–8 GB |
| Compact block filters (P3-D6) | ~12–15 GB | ~1.5 GB |
| LND, wallets, mining, logs | < 10 GB | small |
| Temporary: assumeutxo snapshot + 2nd chainstate during recovery | ~20 GB | — |
| **Total** | **~0.93–0.95 TB** | **~90–120 GB** |

A 2 TB drive gives about 1.8 TiB usable, which leaves **7–9 years** of
headroom. A 1 TB drive is not viable for Phase 3.

---

## 1. Automatic wallet and channel backups off the M.2

### What makes Lightning different

- **`channel.backup` (static channel backup, SCB):** small, encrypted with
  a key from the seed, and written by atomic rename, so a copy is always
  consistent. Restoring from it **force-closes every channel**. The funds
  come back on-chain after peer cooperation and timelocks, which can take
  days. In-flight payments (HTLCs) can be lost. *(verified, LND docs)*
- **`channel.db`:** the live channel state. An **out-of-date copy is
  toxic**. If LND starts from old state, a peer can take the whole channel
  balance as a penalty. LND has no safe live-backup mode, and peer storage
  is not shipped yet. *(verified)*
- The goal is therefore never to *restore a backup of* `channel.db`. Either
  keep a copy of it that is always current (a mirror), or fall back to the
  SCB.

### Options

| | Option | What it protects | Cost / risk |
|---|---|---|---|
| **1A** | **Event-driven SCB + wallet backup to three places** — LND's `SubscribeChannelBackups` stream triggers an immediate copy to (a) eMMC, (b) an encrypted USB stick in the router, (c) optionally an encrypted off-box blob. Core wallet: `backupwallet` after every wallet event, encrypted. | All funds recoverable if the drive dies (channels force-close). | Software only. **Baseline, needed in every design.** |
| **1B** | **1A + a synchronous mirror of the LND and wallet data** — a small md RAID1 volume (about 20–50 GB) across **both NVMe drives**, with a guard against a stale mirror. | A drive death keeps channels **open**, with no force-close. | Needs the second NVMe; md and a stale-member guard need careful testing. |
| 1C | 1A + mirror onto the eMMC instead of a second NVMe | As 1B with one NVMe | eMMC is the system disk: wear, small, slow. Fallback only. |
| 1D | Run LND on the eMMC | — | **Rejected:** still a single device, wears the system disk. |

**Details for 1A** (as recommended by the research):

- **Encryption:** encrypt every off-drive copy to a **public key derived
  from the seed**, so the USB or off-box copy is useless to a finder, and
  the customer only needs the seed to decrypt. This is Umbrel's model
  (encrypted SCB uploaded over Tor). An off-box target could be our server
  or the customer's own cloud.
- **Generation numbers:** each backup set carries a monotonic generation
  number. Restore refuses anything older than the newest it has seen. The
  UI shows "last backup: N seconds ago, in 3 places".
- **Watchtowers** (LND built-in, using a third-party or LSP tower) protect
  channels while the router is offline after a failure.
- **Core descriptor wallet:** export `listdescriptors true` only in
  encrypted form, because it contains private keys. The vault tier
  (P3-D5) is watch-only, so its backup is just the descriptor.
- **Restore test:** the setup wizard proves the USB backup can be read back
  and decrypted, rather than only writing it.

**Recommendation: 1A + 1B.** The one design that keeps channels open
through a drive death is a synchronous mirror across both NVMe slots. 1A
alone is the acceptable minimum, the industry-standard level that
Umbrel and Start9 offer.

---

## 2. Surviving sudden power loss

### What fails

- Consumer SSDs without **power-loss protection (PLP)** can lose the last
  writes in their cache, and a few drives have been shown to ignore flush
  commands. LevelDB (chainstate) and LND's bbolt database are sensitive to
  this.
- A damaged chainstate costs a `-reindex-chainstate`, many hours to days on
  this CPU. A damaged `channel.db` can cost money.
- The `unsafe_shutdowns` SMART counter already tells us when this has
  happened.

### Options

| | Option | Drives (2280, PCIe ≥3) | Notes |
|---|---|---|---|
| **2A** | **Split storage + signalling UPS** | Slot 1: **2 TB consumer TLC** with DRAM (WD SN850X/SN7100, Samsung 990 PRO/990 EVO Plus, Solidigm P44 Pro, Crucial T500) for `blocks/`, electrs and filters, all rebuildable. Slot 2: **Kingston DC2000B 480 GB PLP** for chainstate, wallets and LND. | Bitcoin Core supports this split directly (`-blocksdir`). The irreplaceable data sits on the PLP drive. It also provides the second drive for mirror 1B. **Best protection.** |
| 2B | **One 2 TB PLP industrial drive + UPS** | Transcend MTE712P 2 TB or Innodisk 4TG2-P 2 TB | The only 2 TB PLP drives that fit 2280. Sold through distributors, expensive, and the Transcend is double-sided (check underside clearance). There is no second drive for the mirror. |
| 2C | **One consumer TLC drive + UPS** | e.g. Samsung 990 EVO Plus 2 TB | Cheapest; relies on the UPS and on the drive honouring flushes. |

### Same for every option (software)

- **Filesystem:** ext4, `data=ordered`, write barriers on, no `fast_commit`,
  `errors=remount-ro`. No `discard` mount option; run `fstrim` weekly.
  Avoid btrfs and f2fs for the data drive.
- **UPS signal:** on "mains lost", shut down cleanly: LND, then Core, then
  sync, then unmount. One to two minutes is enough. The router draws about
  15 W, so a small DC UPS lasts much longer.
  - **OpenUPS2:** USB HID, read by NUT.
  - **Mean Well DRC-60A + battery:** its AC-OK relay goes to a GPIO.
  - None of the consumer node products the research found does this.
- **After an unclean shutdown** (the `unsafe_shutdowns` counter
  increased): run LND and Core consistency checks before starting, and show
  "power was lost — a UPS is recommended".
- **Thermal:** both slots face down. Use a thin heatsink or a thermal pad
  to the case, and treat the drive temperature as a monitored value (§3).

**Recommendation: 2A**, with the UPS an optional accessory, recommended in
the box insert. If two drives are too costly or complex for the BOM, use
**2B** and accept 1A-only backups.

---

## 3. Drive health monitoring

### What can be read

- **No extra package:** the kernel exposes the drive temperature and its
  limits (hwmon, `temp1_input`, `temp1_crit`, `temp1_alarm`), the
  controller `state`, model, serial and firmware, and ext4 error counters.
  *(verified, Linux 6.6)*
- **Wear, spare and media errors** need the NVMe SMART log (an admin
  command). On OpenWrt the options are:
  - **`nvme-cli` 2.9.1**: about 1.3 MB installed with libnvme, pure C;
  - **`smartmontools` 7.5**: about 0.6 MB, but it pulls in libstdc++,
    about 2.1 MB.

### Options

| | Option | Notes |
|---|---|---|
| **3A** | **`nvme-cli` + sysfs collector** (shell, procd + cron): temperature every 1 min, SMART log every 15 min, hourly history on the NVMe, rollups for a year; result in `/tmp/knots/diskhealth.json` for the UI. | Smallest. **Recommended.** |
| 3B | `smartctl --json` (Umbrel's approach) + `smartd` | Simpler parsing; +2.7 MB. Only if libstdc++ ships anyway. |
| 3C | Own small ioctl helper | Smallest at runtime; more code to own. Later, if flash space is tight. |

### Thresholds (all options)

| Signal | Healthy | Attention ("plan a replacement") | At risk ("replace now") |
|---|---|---|---|
| `critical_warning` | 0 | bit 1 (temperature) only | bit 0, 2, 3 or 4. **Bit 3 = drive read-only → stop node, rescue mode** |
| Spare vs threshold | ≥ threshold + 20 | < threshold + 20, or −10 points from install baseline | ≤ threshold |
| `percentage_used` | < 80 | 80–99 | ≥ 100 (worded as "rated life used", not "failed") |
| `media_errors` | = baseline | any increase | +10 in 7 days, or still rising |
| Temperature | < warning − 5 °C | ≥ warning temp (70 °C if not reported) | ≥ critical temp (80 °C if not reported) |
| ext4 / kernel | no errors | ext4 `errors_count` > 0 | I/O errors, read-only remount, controller not `live`, drive gone |
| `unsafe_shutdowns` | stable | increased → "power was lost" notice + consistency check | — |

`num_err_log_entries` is informational only, because it is noisy on many
drives. A **baseline** is recorded when a drive is installed, so a used
drive does not alarm on day one. The UI shows the estimated life remaining
from the wear trend.

### How the customer is told

- Node Status card: a colour-coded drive card; Settings: the details.
- A banner on every page for Attention and At-risk, with the action:
  "Back up now", "Order a replacement", "Replace drive".
- **At risk** automatically forces an SCB and wallet backup to every target.
- A router LED pattern (amber) for drive attention, for customers who never
  open the UI.
- Phone push notifications come with the RNode app (Phase 3.1).

**Recommendation: 3A.** It is cheap enough to **back-port to `release/2.x`**,
where it would also have flagged the nearly full drive sooner.

---

## 4. Guided "replace drive" flow

### Today (Phase 2)

`storage-prepare.sh` already formats a **truly blank** drive automatically
and **refuses** any drive with a partition or filesystem signature, so it
never wipes chain data. There is no UI to prepare a used drive, no
migration, and recovery is always a full re-sync (an estimated 3–6 days on
this CPU).

### The wizard (Phase 3)

1. **Before:** force a backup (§1) and prove it reads back. Explain what
   will happen and how long it takes. Stop LND, then Core, then the
   containers; unmount.
2. **Install:** if the old drive still reads, put the new one in the
   **empty slot**. If it is dead, swap it.
3. **Pick the new drive safely:**
   - Only NVMe drives that are not mounted and not the registered data drive.
   - Show model, size, serial and slot; the customer **types the last 4
     characters of the serial**.
   - A drive with existing data needs a second, explicit confirmation.
   - Check its SMART first (no warnings, no media errors, ≥ 1.5 TB).
   - Re-check the serial right before formatting.
4. **Prepare:** GPT + one ext4 partition (`sfdisk`, `mkfs.ext4`), mount by
   UUID with `noatime,errors=remount-ro`. Write a **sentinel file**
   (appliance ID + serial). Containers refuse to start without the right
   mount and sentinel, so a failed mount can never fill the eMMC.
5. **Get the chain back**, choosing the fastest safe path automatically:

| Rank | Path | When | Time (estimate) | Notes |
|---|---|---|---|---|
| 1 | **Copy from the old drive** (slot 1 → slot 2, node stopped, `rsync`) | Old drive still readable (Attention / At-risk) | 1–2 h for ~0.9 TB | No re-sync, channels stay open. If media errors rise during the copy, drop the copied chainstate and use path 2. The old LND data is **retired** afterwards: it must never be started again. |
| 2 | **assumeutxo snapshot** (`loadtxoutset`) + restore wallets and SCB | Drive dead | Usable in hours; full background check takes days | Core checks the snapshot against a hash built into the binary, so we can host it ourselves or ship it on replacement drives or USB. Wallets and LND must wait until background validation passes their birthday. |
| 3 | **Full sync** (or a LAN copy from another node) | Fallback | 3–6 days | Always available; no extra infrastructure. |

6. **Lightning restore:**
   - With path 1, LND starts **once** on the copied state.
   - Otherwise do a seed + SCB restore. The UI explains that channels close
     and funds return over days (`lncli getrecoveryinfo`).
7. Register the new drive (serial, UUID, SMART baseline). Tell the customer
   to wipe or remove the old drive.

### Snapshot freshness

| Node software | Newest snapshot | Blocks behind today's tip (~972k) |
|---|---|---|
| Knots 29.4.2 | 910,000 | ~62k (about 14 months) |
| Core 31.x | 935,000 | ~37k (about 9 months) |
| Core 32.0 (release candidate) | 965,000 | ~7k (about 7 weeks) |

To keep path 2 fast, keep the node software current: move to Core 32 once
it is final, and track Knots for its next snapshot. None of the other node
products exposes assumeutxo in its UI, so this is a differentiator.

**Recommendation:** build the wizard with paths 1 and 3 first, then add
path 2 after a spike proves LND behaves during background validation.
**Ship replacement drives preloaded** with the latest snapshot file, so a
dead-drive replacement needs no large download.

---

## 5. Recommended package

| Need | Recommendation | Fallback |
|---|---|---|
| Off-M.2 backups | **1A + 1B**: event-driven encrypted SCB/wallet backup to eMMC + USB (+ optional off-box), plus an NVMe mirror for LND/wallets | 1A only |
| Power loss | **2A**: 2 TB TLC (blocks) + 480 GB PLP (state), ext4 hardening, UPS shutdown support | 2B: single 2 TB PLP |
| Health | **3A**: `nvme-cli` collector, thresholds above, UI banner + LED; back-port to 2.x | 3B `smartctl` |
| Replace drive | Wizard, paths 1 → 3 first, then assumeutxo (2); preloaded replacement drives | Full sync only |

### Spikes needed (on the R4 Pro)

| Spike | Proves |
|---|---|
| S4 — storage | Both slots detected with our kernel; split `-blocksdir` layout; drive temperatures under IBD in the case; ext4 options |
| S5 — mirror | md RAID1 for the LND/wallet volume across both NVMe drives; stale-member guard; **50 power pulls** with LND under load, zero `channel.db` problems |
| S6 — UPS | OpenUPS2 (NUT) or DRC-60A (GPIO) triggers a clean shutdown in < 2 min |
| S7 — assumeutxo | `loadtxoutset` on the Pro; time to usable; LND and wallet behaviour during background validation |
| S8 — IBD | Measured full sync time and dbcache/LXC memory limits on the Pro (the 3–6 day figure is an estimate) |

---

## 6. Residual risks

- **Drives that lie about flush** would defeat the mirror and the ordering
  guarantees. Mitigation: the PLP drive for state, the power-pull spike, and
  a qualified-drive list. Do not let customers fit any drive they like for
  the state slot.
- **SCB recovery depends on peers** being online and honest; it can take
  days. Watchtowers and a reputable LSP reduce the risk; the UI must set
  expectations.
- **Off-box backup** adds a server we must run, or a dependency on the
  customer's cloud. It stays opt-in.
- **Stale LND state** from an old drive is the main way a customer can lose
  money by mistake. The wizard retires the old data, and LND refuses to
  start without the current sentinel and generation.
- **Snapshot freshness** depends on our release cadence.
- **Underside slots** make thermals and serviceability case-dependent.
- **No official OpenWrt image for the Pro yet**, so kmods and the NVMe
  driver come from our build (spike S0).

---

## 7. Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| P3-D18 | Storage hardware: split (2A), single PLP (2B), or single consumer (2C)? | 2A |
| P3-D19 | Lightning state: mirrored across two NVMe drives (1B) or SCB-only (1A)? | 1A + 1B |
| P3-D20 | Offer an encrypted off-box backup (our server or the customer's cloud)? | Yes, opt-in |
| P3-D21 | UPS: supported accessory (which model), or recommended only? | Supported, one model |
| P3-D22 | Back-port drive health monitoring (3A) to `release/2.x`? | Yes |
| P3-D23 | Phase 2 retail drive size (1 TB is nearly full now) | 2 TB |

---

## Main sources

- LND disaster recovery and SCB: docs.lightning.engineering (disaster-recovery, `SubscribeChannelBackups`)
- Bitcoin Core: `doc/assumeutxo.md`, `doc/files.md` (`-blocksdir`, `xor.dat`), `doc/reduce-memory.md`, release notes 28.0 / 31.0, `chainparams.cpp` for 28.x–32.0rc4; Knots v29.4.2 chainparams
- Linux 6.6 `drivers/nvme/host/{hwmon,sysfs}.c`; libnvme `nvme_smart_log`; smartmontools `nvmeprint.cpp`, tickets 1222 / 1806
- OpenWrt 24.10.8 package index (aarch64_cortex-a53); `kmod-nvme` in `package/kernel/linux/modules/block.mk`
- BPI-R4 Pro: docs.banana-pi.org; CNX Software
- Other node products: Umbrel storage manager and `internal-storage.ts`; Start9 transfer/backup docs; RaspiBlitz storage migration and `blitz.copychain.sh`; myNode clone tool
- Lopp: 2025 node performance tests; dbcache effects; UTXO-snapshot sync
- Schroeder et al., FAST '16 (SSD field reliability)
