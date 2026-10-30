# RNode development and release methodology

**Status:** agreed direction (owner, 2026-10-28) — before the first public repository.
**Goal:** work the way RNode's two upstream projects work — **OpenWrt** (the router
system) and **Bitcoin Core** (the node) — so RNode fits with them, stays open
source under its licence, and can grow from two maintainers (the owner and his
partner) into a community project.

**Node software — freedom of choice, Core by default** (owner, 2026-10-28).
RNode exists to enable bitcoin and the owner's freedom to choose: the person
running the router chooses which node implementation to follow (today: Bitcoin
Core or Bitcoin Knots, both following bitcoin), and RNode's job is to install
each one **authentically** (checked with that project's own release signatures)
and to say **plainly** what each choice means. **Bitcoin Core is the default**,
and the default sets RNode's release rhythm and version number.

---

## 1. How the upstream projects do it

### Bitcoin Core (and Bitcoin Knots)

| Area | Bitcoin Core |
|------|--------------|
| Licence | MIT |
| Code | One public repository (github.com/bitcoin/bitcoin). Anyone **forks** it and sends changes as **pull requests** |
| Review | Public review on each pull request; a small group of maintainers merges. Merge commits are signed with the maintainers' **PGP** keys, and the repository keeps the list of those keys to check them |
| Releases | A release branch per major version, **release candidates** (rc1, rc2 …) for testing, then a **signed tag** and release notes |
| Builds | **Reproducible builds** (Guix): anyone who builds a tag gets byte-identical files |
| Trust | No single release key. Independent builders publish the hashes of their own builds, signed with their own PGP keys, in a separate repository (**guix.sigs**, one folder per version and signer, builder keys in `builder-keys/`). `SHA256SUMS.asc` carries many signatures; since v22.0 the user decides which signers to trust ([guix.sigs](https://github-redirect.dependabot.com/bitcoin-core/guix.sigs), [verify-binaries](https://github.com/bitcoin/bitcoin/blob/master/contrib/verify-binaries/README.md)) |

**Bitcoin Knots** is a derivative of Bitcoin Core (also MIT) maintained by Luke
Dashjr — offered in RNode as a choice (see the top). *To check* before the
signature check script relies on it: who signs Knots releases and where its
checksum and key files live (not confirmed when this document was written).

### OpenWrt

| Area | OpenWrt |
|------|---------|
| Licence | GPL-2.0 (most of it; packages carry their own licences) |
| Code | git.openwrt.org with a GitHub mirror; changes by **pull request** or the mailing list |
| Contributions | Every commit carries a **Signed-off-by** line (Developer's Certificate of Origin 1.1, `git commit -s`); one logical change per commit ([submitting patches](https://openwrt.org/submitting-patches)) |
| Releases | A **stable branch per series** (e.g. `openwrt-24.10`), release candidates, then **service releases** (24.10.1, 24.10.2 …) for fixes and security |
| Signatures | Release checksum files signed with **GPG** (`sha256sums.asc`); package feeds signed with **usign** (Ed25519), which the router checks itself. Keys have been **per release series**; since 23.05 the snapshot key signs while the signing set-up is being reworked ([release signing](https://openwrt.org/docs/guide-user/security/release_signatures), [public keys](https://openwrt.org/docs/guide-user/security/signatures)). *To check* the current keys before relying on them |

---

## 2. What RNode does — in line with both

| Area | RNode | Taken from |
|------|-------|------------|
| **Licence** | **GPL-2.0-only** for RNode's own code (`LICENSE`, `NOTICE.md`); OpenWrt, Bitcoin Core, Bitcoin Knots, LXC, Debian packages keep their own licences | OpenWrt |
| **Repository** | **One public repository.** People develop in **forks** and send **pull requests** (no separate "community repository" — forks are that) | both |
| **Contributions** | Every commit **Signed-off-by** (DCO, `git commit -s`); one logical change per commit; public review on the pull request (ACK / NACK) | OpenWrt + Core |
| **Who merges** | The **maintainers** (now: the owner and his partner). `main` is protected; every merge commit and release tag is **signed with the maintainer's PGP key**; `MAINTAINERS` lists the keys; maintainers merge with `contrib/merge-pr.sh`, and `contrib/verify-commits` (run by GitHub after every push) confirms every commit on `main` and every release tag is signed by one of them | Core |
| **Pushing** | Over **SSH** (`git@github.com:…`), never HTTPS — the SSH key is the maintainer's PGP **authentication subkey** | — |
| **Node software** | The owner of each router **chooses** the implementation (Core, Knots, others later); **Bitcoin Core is the default**. Each offered implementation is pinned and checked with **its own** project's signatures; Setup / Settings explain what each choice means. RNode's release rhythm and version follow the **default** (Core) | Core + RNode's principle of choice |
| **Branches & versions** | `main` for development; a **release branch per OpenWrt stable series** (e.g. `rnode-24.10`); release candidates (`…-rc1`); **maintenance releases** when OpenWrt ships a service release, **Core** a point release, or RNode needs a fix. Version = **`{OpenWrt}.{Core}.{build}`** (e.g. `24.10.8.29.4.119`) — changing from today's `{OpenWrt}.{Knots}.{build}`; the build number keeps counting up | OpenWrt + Core |
| **Upstream inputs** | Every upstream file is **pinned by SHA256** (already: Image Builder, Core, Knots, Debian image) **and** checked with the upstream project's **own signatures** when the version changes — OpenWrt's signed checksums and Core's multi-signer `SHA256SUMS.asc` (and each other offered implementation's own release signatures, e.g. Knots) — by a script whose output is kept with the release | both |
| **Reproducible builds** | Goal: anyone who builds a release tag gets the **same SHA256** (fixed inputs, fixed time stamps, no unpinned downloads during the build) | Core |
| **Attestations** | A second public repository, **`rnode-sigs`**: per release, each builder's folder holds `SHA256SUMS` and their PGP signature `SHA256SUMS.asc` | Core (guix.sigs) |
| **Firmware signature (on the router)** | **usign** (OpenWrt's tool), appended to the image; the router accepts only images signed by a **maintainer's firmware key**. Each maintainer has **their own** usign key, and **signs its public half with their PGP key** (PGP identity → firmware key → release) | OpenWrt (usign) + Core (one key per person) |
| **Downloads** | Published with `SHA256SUMS` and `SHA256SUMS.asc` (signed by each maintainer who built or checked it) | both |
| **Source for every release** | The signed tag is the exact source. For the GPL components, each release lists the exact OpenWrt release, Image Builder and package versions it was built from (their source is on OpenWrt's mirrors) and offers it with the firmware (GPL-2.0 section 3) | OpenWrt / GPL |

**Not part of the open-source project:** the **factory key and the factory
station's data** (sticker passwords, inventory). That is the manufacturer's
work. The station's code is public; the factory key never is.

---

## 3. Keys

Each maintainer looks after **their own** keys — there is no shared project key.

| Key | Purpose | Where it lives |
|-----|---------|----------------|
| **PGP primary key** (one per maintainer) | Creates / renews / revokes the subkeys below; certifies the maintainer's firmware key | **Offline**: encrypted sticks (primary + backup, different places), used only in the live-USB session (`factory/offline/rnode-offline.sh`) |
| PGP **signing** subkey | Signs commits, merges, tags, `SHA256SUMS.asc` | Hardware security key (preferred) or the maintainer's computer, passphrase-protected; expires after 1–2 years |
| PGP **authentication** subkey | SSH key for pushing to the repository | Same as the signing subkey |
| **Revocation certificate** | Revokes the PGP identity if it is lost or stolen | Paper / backup stick, with the key backups |
| **Firmware key** (usign, one per maintainer) | Signs release images; routers check it | **Offline**, on the same encrypted sticks (primary + backup) |

- **Hardware security key** for the PGP subkeys: each maintainer's choice, as in
  Bitcoin Core (no project rule there — builders list their PGP fingerprints in
  `contrib/builder-keys`). RNode asks only that the signing subkey is never a
  plain file on an online computer: on a hardware key (YubiKey 5 with firmware
  5.7+, or Nitrokey 3) or passphrase-protected. Firmware (usign) keys cannot
  live on these devices — they stay on the encrypted sticks.
- **Losing a key:** the other maintainer signs the next release, which removes the
  lost firmware key and adds the replacement; a lost PGP identity is revoked.
- **Changing who routers trust** only ever happens through a **signed release**.
- **Now:** routers accept a release signed by **any one** maintainer.
  **After reproducible builds:** routers require **two** maintainers' signatures.
- The keys made on 2026-10-27 (A `2e51b93dd6058ffb` = the owner's firmware key;
  B `833eb2b299741478` = his standby) move to this model: **A stays the owner's
  firmware key**, copied to a backup stick; **B is retired** in the first public
  release, which adds the partner's own firmware key.

---

## 4. A release, step by step

1. **Freeze**: pick the commit on the release branch; update upstream pins if needed
   (the upstream-signature check script must pass).
2. **Release candidate**: tag `…-rc1` (signed), build, test on hardware
   (the Release 1 gate: build through the station, Setup, secure connection on
   Mac / Windows / Linux, node stop / start, reboot, shutdown, power cut,
   factory reset, upgrade keeping and resetting settings).
3. **Final tag**: signed by a maintainer.
4. **Build**: `make image RELEASE=1` — each maintainer builds independently;
   (after reproducible builds) the SHA256s must match.
5. **Firmware signature**: offline, with a maintainer's firmware key
   (`rnode-offline.sh`, choice "sign"); `make store-release`.
6. **Attest**: each maintainer commits `SHA256SUMS` + their `SHA256SUMS.asc` to `rnode-sigs`.
7. **Publish**: the signed image, `SHA256SUMS`, `SHA256SUMS.asc`, release notes,
   and the source / GPL notice; the factory station installs the signed release.

---

## 5. Phases

| Phase | What |
|-------|------|
| **1 — now** | Public repository (fresh history from Release 1, without internal lab notes) + `rnode-sigs`; `CONTRIBUTING.md` (forks, pull requests, Signed-off-by, review), `SECURITY.md`, `MAINTAINERS`; each maintainer's PGP identity and firmware key made offline; the first public release trusts the owner's and the partner's firmware keys; signed merges, tags and `SHA256SUMS.asc`; SSH-only pushes |
| **2** | Reproducible builds; upstream-signature check script; routers require **two** maintainers' signatures |
| **3** | More maintainers and independent builders from the community; trust list changes by signed release only |
