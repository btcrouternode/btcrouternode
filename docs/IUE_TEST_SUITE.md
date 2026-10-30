# IUE / first-run Setup test suite

**Authority:** U17, U19, R7, R10a, R13, N13 · `docs/FIRST_RUN_UX.md`  
**Run:** `make test-iue` (host always; device when `/dev/ttyUSB0` or `SERIAL=` set)  
**Also included in:** `make test-host` via `tests/host/run-iue.sh`

## What it covers

### Host — Setup flow (`test-iue-flow.sh`)
User journey contract without a board:

| Scenario | Check |
|----------|--------|
| Step order | Welcome → **HTTPS trust** → Locale → Password → WAN → Wi‑Fi → Node → Advanced → Done |
| Gate | `shell.js` redirects to Setup until `setup-complete` |
| API surface | status, locale, password, wan_*, wifi, node, lan, complete |
| Complete closed | Requires locale + password markers |
| Password | Factory `knotsnode21` forbidden; min 8 |
| Wi‑Fi | Factory AP `rnode` / `knotsnode21`; new key 8–63 (not factory); country `00` or ISO; reload at complete |
| WAN | DHCP + PPPoE + Skip |
| TLS UI | Detected OS only; optional other-OS reveal; all OS panels present |
| U19 | Language packs + regions catalog present |

### Host — Cert install all OSes (`test-iue-tls-os.sh`)
Simulates each OS install path with a **real** CA from `node-ui-tls.sh`:

| OS | Simulated user path |
|----|---------------------|
| **Windows** | Primary CTA = `.bat`; bat self-fetches `.ps1`; PEM validate; `certutil` present in script |
| **macOS** | Primary CTA = `.mobileconfig`; profile PayloadContent == CA DER; optional Terminal helper with fake `sudo security` |
| **iPhone / iPad** | Same Apple profile; iPadOS desktop-UA detection |
| **Android** | Primary = `knots-ca.crt`; alternate `.cer` DER; Settings copy in UI |
| **Linux** | Download helper; `chmod +x` gate; fake `sudo` trust-store install; reject bad CA; fetch CA from router URL |

Also asserts nginx `Content-Disposition: attachment` for every helper (no “heap of text” in the browser).

### Device (`test-iue.sh`)
On the live router (serial): Setup API status, published CA, download headers, OS tabs on disk, factory-password / short-wifi / complete-prereq negatives. Does **not** wipe M.2 or force Setup complete.

## Looking for bugs
These tests fail on missing steps, wrong OS CTA, broken mobileconfig, missing Disposition headers, hostname regressions, and install helpers that accept garbage “certificates.”
