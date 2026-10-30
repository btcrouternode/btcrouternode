# Security zone tests (T5 / NF10) — Phase 2 retail isolation

**Authority:** REQUIREMENTS **T5**, **NF10**, **N2**, **N6**, **N8**, **N12**, **DOC4**  
**When:** After a complete build (incl. Wi‑Fi Setup) — before community ship / first sold units.  
**Rule:** Real interfaces/zones only; do not wipe M.2.

---

## Zones

| Zone | Script | Where you run it |
|------|--------|------------------|
| **LAN** (Ethernet) | `tests/security/run-from-lan.sh` | PC on LAN `192.168.1.0/24` |
| **Wi‑Fi** | `tests/security/run-from-wifi.sh` | PC associated to `brnode` (then same L3 as LAN) |
| **WAN** | `tests/security/run-from-wan.sh` | PC on WAN/modem side |
| **DMZ + UCI** | `tests/security/run-on-router-dmz.sh` | On the router (SSH/serial) — proves **DMZ ↛ LAN** |

Orchestrator: `tests/security/run-all.sh`

---

## Pass criteria (summary)

| From | Expect |
|------|--------|
| LAN / Wi‑Fi | UI **80/443**, LuCI **8080** open; RPC **8332** closed (default); extra junk ports closed |
| WAN | **80/443/8080/8443/22/8332** closed (stress rounds); **8333** may be open (P2P DNAT IPv4 + IPv6 **N6a**) |
| DMZ | No `dmz→lan` / `wan→lan` forwarding; `dmz.forward=REJECT`; cannot TCP to LAN hosts; WAN DNAT 8333 correct; UPnP off; LAN RPC redirect disabled |

Retail: `RETAIL=1` makes LAN **SSH** a hard FAIL if open.

---

## Examples

```bash
# LAN PC
ROUTER_LAN_IP=192.168.1.254 ./tests/security/run-from-lan.sh

# Wi‑Fi (after Setup set brnode)
RUN_WIFI=1 WIFI_PSK='your-wifi-password' ./tests/security/run-from-wifi.sh
# or already connected:
SKIP_ASSOC=1 ./tests/security/run-from-wifi.sh

# WAN PC (use address from router: ifstatus wan)
ROUTER_WAN_IP=203.0.113.10 ./tests/security/run-from-wan.sh

# On router
sh /root/run-on-router-dmz.sh
# optional: prove against a real LAN laptop
LAN_TARGET=192.168.1.105 sh /root/run-on-router-dmz.sh

# Via SSH from lab PC
ROUTER_SSH=root@192.168.1.254 ./tests/security/run-all.sh
```

Makefile: `make test-zone-security` (LAN + optional SSH on-router; WAN/Wi‑Fi via env).

---

## Community reviewers

Point UX reviewers at Setup / Status. Point network-capable reviewers at this doc + WAN + DMZ scripts. Record pass in `docs/AS_BUILT.md`.
