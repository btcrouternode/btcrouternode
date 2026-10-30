# Privacy payments (P2B-D / M-B)

**UI:** `https://192.168.1.254:21443/privacy.html`  
**CLI:** `/usr/libexec/knots/privacy-ensure.sh status|enable|disable|configure`

## Software
**JoinMarket-NG** with `backend_type = descriptor_wallet` against this appliance’s Knots node (`21.21.21.21:8332`, cookie `/mnt/bitcoin/.cookie`).

## Default UX
**Taker-first** — when CoinJoin is unlocked, the primary path is paying to mix (taker). Maker (provide liquidity) is not the default for non-experts.

## Sync gate
While Knots reports `initialblockdownload=true`, CoinJoin stays **gated**. Enabling the module only prepares config/state.

## Install (on device, after sync preferred)
Inside Knots LXC, with spare RAM (stop Lightning if needed):

```sh
export JOINMARKET_DATA_DIR=/mnt/bitcoin/joinmarket-ng
# install.sh --taker  (add Tor for live directory; --skip-tor for offline prep only)
```

Then host: `privacy-ensure.sh configure && privacy-ensure.sh enable`.

## Threat
Hot keys on appliance. Backup JM wallet material offline. No custodial mixer. LAN management only.
