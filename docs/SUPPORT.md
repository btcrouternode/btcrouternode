# RNode support articles

Short answers for the questions testers and customers will ask. Written for
someone who is not technical; each article says what happened, then what to do.
Applies to firmware `25.1.32.0` and later unless noted. The full user guide is
[USER_GUIDE.md](USER_GUIDE.md).

---

## 1. The browser shows a security warning after a reset or a fresh upgrade

**Why:** every factory reset, and every upgrade with **Reset settings**,
gives the router a brand-new security certificate. Computers and phones that
trusted the old one do not know the new one yet. Nothing is wrong with the
router.

**What to do (each computer or phone you use with the router):**

1. Open `http://192.168.1.254/` (plain `http`) — it shows **Add this computer**.
2. Click **Enable Secure Connection** and follow the steps for your computer.
   Windows: open the downloaded file and answer **Yes**. Mac: **Allow** →
   **▶ Run** in Script Editor. Linux (Ubuntu, Debian, Mint): open the
   downloaded `.deb` and click **Install**. Each asks for **your computer's**
   password, not the router's.
3. If the page does not move on by itself, close the browser completely and
   open it again.

The installer prints a "fingerprint" (a long line of letters and numbers).
It must match the one under **Settings → Renew HTTPS certificate** on a
device that already trusts the router.

---

## 2. I forgot the Wi‑Fi password

**If you know the router password:**

1. Connect a computer to the router with a network cable.
2. Open `https://192.168.1.254/` → **Router settings** → log in as `root`
   with the router password.
3. **Network → Wireless** → **Edit** on each `rnode` network →
   **Wireless Security** → set a new key (8–63 characters) → **Save & Apply**.

**If you do not know the router password either:** do a factory reset
(article 4). Your blockchain copy is kept; you will go through Setup again.

The Wi‑Fi password cannot be read from the web pages without logging in —
that is deliberate.

---

## 3. I can't open `rnode.local`

Some computers and phones do not support `.local` names (VPNs, some company
laptops, some Android phones). Use one of these instead — they all work:

- `http://192.168.1.254/` (or the router's address if you changed it in Setup)
- `http://node-router/` when the computer uses the router for DNS
- this unit's own name, `http://rnode-XXXX.local/` — printed on the label and
  shown under **Settings → This router's own address**

The pages remember the address you used, so you can keep using the IP address.

---

## 4. Factory reset

**From Settings (preferred):** **Settings → Factory reset** → router
password → type `RESET` → **Reset to factory defaults**. Takes about 11
minutes; keep the page open. The router then opens Setup.

**With the button (router password unknown):** hold the **WPS** button for
5 seconds or more, then release. Wait about 11 minutes. (A short press only
restarts the router. The **RST** button restarts it instantly and does not
reset anything.)

**After a reset:**

- The router is back at `192.168.1.254`.
- Router password: the one on the label.
- Wi‑Fi: `rnode` with the password on the label.
- The blockchain copy on the M.2 drive is **not** erased.
- A new security certificate is created (article 1).

---

## 5. Two RNodes on the same network

Only one of them can answer as `rnode.local`. Every unit also has its own
name, `rnode-XXXX.local` (on the label, and in **Settings → This router's own
address**) — use that, or the unit's IP address.

---

## 6. Upgrade problems

- **"SHA256 does not match"** — the file is incomplete or not the one you
  meant. Nothing was changed. Download it again.
- **"This image is not signed" / "signature is not valid"** — only on units
  whose firmware contains the RNode release key: the file is not an official
  release, or was modified. Nothing was changed.
- **My node settings went back to the defaults after upgrading from
  `25.0.32.0`.** That release did not keep them across an upgrade. Set them
  again in **Settings → Bitcoin node configuration**; from `25.1.32.0` on they
  are kept.
- **Updating from `24.10.8.29.5.119` shows *Firmware Update Failed*
  (*sysupgrade exited rc=1*).** OpenWrt 25.12 cannot keep 24.10 settings (its SFP ports were
  renamed). Nothing was changed. Update again with **Reset settings**: the
  blockchain is kept and Setup runs again ([release notes](releases/25.1.32.0.md)).
- **The upgrade page shows `rnode.local` cannot be found** — wait 15 minutes
  from clicking **Verify & upgrade**, then open `http://192.168.1.254/`.

---

## 7. Node Status shows 0 % or an error right after Setup or an upgrade

Normal for the first few minutes while the Bitcoin node starts. It shows the
real progress again within about 5–10 minutes. If it still shows an error
after 30 minutes, use **Settings → Node start / stop** to stop and start the
node, and contact support if that does not help.
