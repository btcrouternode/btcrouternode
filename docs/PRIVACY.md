# Privacy payments (P2B-D / M-B)

> **Not in the current firmware.** This page describes a planned feature
> (product phase 3). Firmware 25.x does not include it: the node's wallet
> is disabled and no Privacy page exists. See [USER_GUIDE.md](USER_GUIDE.md)
> for what RNode does today.

**UI:** `https://192.168.1.254:21443/privacy.html`  
**CLI:** `/usr/libexec/knots/privacy-ensure.sh status|enable|disable|configure`

## Software
**JoinMarket-NG** with `backend_type = descriptor_wallet` against this appliance’s node (`21.21.21.21:8332`, cookie `/mnt/bitcoin/.cookie`).

## Default UX
**Taker-first** — when CoinJoin is unlocked, the primary path is paying to mix (taker). Maker (provide liquidity) is not the default for non-experts.

## Sync gate
While the node reports `initialblockdownload=true`, CoinJoin stays **gated**. Enabling the module only prepares config/state.

## Install (on device, after sync preferred)
Inside the node container, with spare RAM (stop Lightning if needed):

```sh
export JOINMARKET_DATA_DIR=/mnt/bitcoin/joinmarket-ng
# install.sh --taker  (add Tor for live directory; --skip-tor for offline prep only)
```

Then host: `privacy-ensure.sh configure && privacy-ensure.sh enable`.

## Threat
Hot keys on appliance. Backup JM wallet material offline. No custodial mixer. LAN management only.
