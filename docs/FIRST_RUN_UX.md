# First-run user experience (LOCKED)

**Status:** LOCKED — Phase 2 retail · **amended IUE v2, 2026-09-11** (external tester feedback: rnode.local entry, 3-page wizard, Quick/Guided Setup, Security page with one-button trust install, Core default node, SSID `rnode`) · **amended 2026-09-17** (IUE on factory Wi‑Fi `rnode` / `knotsnode21`) · **amended 2026-09-18** (staged Finish: LAN IP + Wi‑Fi apply once at the end; Windows and Linux)  
**Authority:** `REQUIREMENTS.md` **U17**, **U19**, **R4**, **R7**, **R10**, **R10a**, **R13**, **U6**, **U1b**, **N13**, **B15**  
**Decision:** AS_BUILT **D41** (flow), **D46** (HTTPS trust), **D47** (language & timezone); **D49** (HTTPS trust first)  
**Elaboration:** `TECH_SPEC.md` §7.6  
**Status:** Implemented in tree (`setup.html`, `/api/setup`); lab boards should keep `setup-complete` until you want to test the wizard.

---

## 1. Audience story

A person with **zero computer experience** unboxes the appliance anywhere in the world, plugs **WAN**, joins Wi‑Fi **`rnode`** with password **`knotsnode21`** (or uses a LAN cable), opens **`http://rnode.local/`** (mDNS; the LAN IP `http://192.168.1.254/` works too), and is guided tap-by-tap through Setup: **Welcome** → **Security** (one orange button downloads a small trust installer; their own device asks for its own password to approve it — the page shows progress and moves to HTTPS by itself) → **Quick Start** (new router + Wi‑Fi passwords, done) or **Guided Setup** (full control). They never need CLI for the happy path. Language & timezone come from the browser automatically (changeable on the Setup page or later in Settings; LuCI follows the same language).

**Zero-tech rule:** Every Setup step must say what to tap, which dialogs may appear, where files go, and what “done” looks like. Do not assume the user knows Downloads, Terminal, or browser download arrows.

---

## 2. Look and feel (required)

Setup must feel like the same product as **Node Status**, not a different app and not LuCI.

| Must match Node Status | Detail |
|------------------------|--------|
| Brand / chrome | Same brand bar / product header patterns (`shell.js` / Knots brand helpers) |
| Theme | Light and dark via **U1b** |
| Visual system | Shared `app.css` |
| Tone | Calm, plain language |
| Must not | LuCI layout/skin; one-off “wizard theme”; purple generic AI chrome |

---

## 3. Gate

Until setup is marked complete (`/etc/knots/setup-complete`):

1. Node UI redirects to Setup (except Setup, TLS help/assets, APIs, CA). **Initial Setup connection uses HTTP `:80`** until the Security step succeeds; then the wizard continues on **HTTPS** (**N13** / **U17**). CA/`/tls/*` stay on HTTP. **All redirects are `302` + `Cache-Control: no-store` — never `301`** (browsers cache 301 permanently; a returning browser would replay it into a cert warning after a reflash/reset, before Setup can start on HTTP — **F135**). While Setup is incomplete, *no* `:80` path redirects to HTTPS (stray requests 302 to `/setup.html`). Entry name: **`rnode.local`** (mDNS via avahi + dnsmasq record for non-mDNS clients; SANs cover it).  
2. LuCI on **8443** (8080 redirects).  
3. Setup is **LAN only** (Ethernet or the factory **`rnode`** AP — both are the LAN zone).  
4. Lab may pre-mark complete; retail must run Setup when factory password is still in effect (**R13**).
5. After **factory reset** (**N3** — Settings **Reset to factory defaults** → full **`/reset.html`**, CLI, or **hold WPS ≥5 s**; silkscreen **RST** is hardware reboot only on BPI-R4), Setup markers are cleared and this gate applies again — user must complete IUE. The reset page shows **Router Resetting to Factory Defaults** with a progress bar, then opens Setup.

---

## 4. Flow (normative — IUE v2)

```
Page 1  Welcome                 [HTTP — "Welcome to RNode and the Bitcoin Ecosystem.", Continue]
Page 2  Security                [HTTP until trust installed — one-button download + run;
                                 live progress; auto-switch to HTTPS on probe success; Skip allowed]
Page 3  Setup                   [HTTPS — two paths:]
          Quick Start           [defaults; router password + Wi‑Fi password; WAN DHCP auto
                                 with ISP popup on failure; browser-detected locale]
          Guided Setup          [Node (Core default) → WAN (DHCP/PPPoE) → LAN (optional)
                                 → Wi‑Fi (SSID rnode) → Router password]
        → Done → Node Status (HTTPS)
```

### Page 1 — Welcome (step 0)
- “**Welcome to RNode and the Bitcoin Ecosystem.**” Short body (router + full node, a few minutes). Join Wi‑Fi **`rnode` / `knotsnode21`** or stay on a LAN cable; WAN cable if they have one; single **Continue** button.

### Page 2 — Security (step 1, N13) — HTTP until trust installed
- **Why here:** so the rest of Setup (and Node Status) can use **HTTPS** without a browser warning.
- Copy: we make sure **your connection to your router is secure, which means it is safe**. Click **Enable Secure Connection** — a small file downloads; **open it and follow the prompts**; you will need to provide **the password to this device**.
- **No password field on the page.** A web page cannot run code on the visitor’s computer nor use the computer password; the per-OS installer does the work locally, and the OS prompts natively. (Design constraint accepted 2026-09-11.)
- Primary CTA: **Enable Secure Connection** (orange) — detects the OS and downloads the matching installer (`/tls/*`, HTTP).
- **Progress bar:** honest stages — downloading → waiting for the installer → verifying → secured; on success the page switches to **HTTPS** automatically (probe + soft reload, no manual browser quit) and **continues at Choice** (Quick Start / Guided) — never Welcome. `https://rnode.local/` mid-IUE also resumes at Choice (`after_tls=1`). **Linux + Firefox:** the installer must quit Firefox to write Firefox’s own store, then **reopens** `https://<host>/setup.html?after_tls=1` (same outcome as the page soft-reload — the user does not type the address).
- **Download callout (Windows and other download OSes):** after clicking Enable Secure Connection, watch the **top right** of the browser / downloads arrow; click **Allow** / **Save** / **Keep** if asked — **required in Firefox** or the file never downloads. The file should save to **Downloads**, not open as a page of text.
- **Linux:** primary path is **Ctrl+Alt+T** then paste the one-line `wget … | sh` (password in Terminal; typing invisible). The Terminal stays open; Firefox restarts onto HTTPS Setup. **Enable Secure Connection** (file download + `chmod +x`) lives inside collapsed **Step-by-step help**, not on the main Linux page.
- **Different operating system** tabs (Windows / macOS / iPhone / iPad / Android / Linux) stay **visible** on the Security page, **outside** the help block.
- **Step-by-step help for your device** starts **collapsed**. Windows steps: Allow/Save/Keep → Downloads `install-bitcoin-node-trust.bat` → Unknown Publisher **Run** → black & blue windows then UAC **Yes** → press any button to close the black window.
- **Skip for now** allowed (HTTPS may warn until CA installed). `/tls.html` remains help. **I’ve finished — continue** remains as the manual verify path.
- **Same certificate** covers Node UI (`:443`) and Router settings / LuCI (`:8443`) — one install covers both (Chrome/Edge/Safari via OS trust; **Firefox** uses its own store — installer/guidance covers it).

### Page 3 — Setup (step 2 choice, HTTPS)
Two cards:
- **Quick Start** — note: *recommended for non-technical people — the factory settings are used, which is fine.*
- **Guided Setup** — note: *recommended for technical people — customise the Wi‑Fi name, LAN IP range and node choice.*
- **Language & timezone (U19):** auto-detected from the browser (IANA `Intl` timezone → regions catalog → Wi‑Fi country; `navigator.language` → shipped packs) and shown for confirmation; a collapsible **Change language or timezone** control edits it. Applied silently on either path (Quick Start payload / Guided on entry). Unmatched zones fall back to the catalog default and remain editable later in Settings.

**Staged Finish (required — Windows and Linux):** The factory LAN IP (`192.168.1.254`) and factory AP (`rnode` / `knotsnode21`) stay up until they tap Finish. Guided Node / LAN / Wi‑Fi choices are stored, not applied to the live AP or LAN address. Do **not** `ifup lan` or `wifi reload` on the LAN or Wi‑Fi steps. Locale and the new router password apply when chosen (the password must not be written to a staging file). WAN DHCP/PPPoE may apply when chosen so the internet check is real (**R10a**) — that does not drop the Setup client.

#### Quick Start (step 3)
- Copy: set a **new router password** and a **new Wi‑Fi password** — neither may be the factory password **`knotsnode21`**. Everything else uses factory defaults (Wi‑Fi name **`rnode`**, **Bitcoin Core** node, automatic internet).
- WAN: DHCP auto-check runs in the background with a status line; on failure an **ISP login popup** (PPPoE username/password) appears — Skip allowed (**R10a**).
- One **Finish setup** button → single `quickstart` API call (locale + admin password + node Core + WAN DHCP + Wi‑Fi `rnode` UCI) → JSON back to the browser first → **one** cutover (radio reload) → `setup-complete` → dashboard (HTTPS). If they are on Wi‑Fi, Finish shows **join `rnode` with the password you just chose** (~3 minutes). Ethernet stays up. No-radio units hide the Wi‑Fi fields and skip Wi‑Fi.

#### Guided Setup (steps 4–8)
- **Node (4):** **Bitcoin Core pre-selected (recommended)** vs Knots (**B15**). Choice is staged; `bitcoind` switches at Finish.
- **Internet/WAN (5):** DHCP auto-try, then Retry / ISP login (PPPoE) / Skip (**R10a**). WAN may apply here (does not drop LAN/Wi‑Fi).
- **Advanced — LAN (6):** collapsed by default; optional LAN IP range. Saving **stages** the new address only — the live router IP does not change and Setup continues on this same page to Wi‑Fi. No wait page and no reboot on this step.
- **Wi‑Fi (7):** SSID defaults to **`rnode`** (editable); new password required, **8–63** ASCII, confirm, **not** `knotsnode21`; country pre-filled from the detected timezone (editable). Factory AP uses country **`AU`** until that locale step (hostapd rejects `00`). Save **stages** SSID/PSK; the factory AP stays up. Continue to **Router password**. No radio → continue.
- **Router password (8):** ≥8, confirm, cannot skip on retail (**R13**). Shown after Wi‑Fi — same password as Settings / LuCI. Applied when saved (not staged). Required text/password boxes are light red until filled (confirm pairs turn green when they match, same as other password fields).
- **Done (9) / Finish:** one cutover applies staged node + LAN + Wi‑Fi. If the LAN IP changed: keep the previous address as a short-lived alias (~2 minutes), reissue the HTTPS leaf with **both** IPs + `rnode.local` (same CA — visitors do not reinstall trust), then drop the alias. If SSID/PSK changed: reload radios after JSON is returned. If only the LAN IP changed: deauthenticate Wi‑Fi stations (AP stays up) so clients DHCP-renew. **One** wait page (~3 minutes) tells them to join the chosen SSID (toggle Wi‑Fi if needed) and, if the IP range changed, to wait for a new address; then opens **`https://rnode.local/`** Node Status. Do not send the browser to `https://<lan-ip>/`. `/etc/hosts` + Avahi keep `rnode.local` pointed at the current LAN address after a range change.

---

## 5. Out of scope for Setup

Appliance upgrade, bitcoin.conf, wipe, reindex, Tor, wallet/LN/privacy, custom ISP VLAN (LuCI). Full translation of every Phase 3 page — v1 covers Setup + primary chrome + Node Status / Settings / Node software key strings; missing keys fall back to English (new IUE v2 copy ships English-first).

---

## 6. Happy path

Plug WAN → join **`rnode` / `knotsnode21`** (or LAN cable) → open **`http://rnode.local/`** → **Welcome** → **Security** (Enable Secure Connection → run installer → page moves to HTTPS by itself) → **Quick Start** (new router password + new Wi‑Fi password → Finish → **one** rejoin of `rnode` with the new password if they were on Wi‑Fi) → Node Status (**HTTPS**). Technical users may choose **Guided Setup** (customise node / WAN / LAN / SSID, still **one** Finish cutover). Factory reset and firmware update with reset-settings reopen **Welcome** (`http://rnode.local/setup.html?step=0`), not a mid-wizard page.
