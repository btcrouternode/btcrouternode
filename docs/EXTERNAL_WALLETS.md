# External wallets (P2B-B)

**Maps to:** W4, W9, W10, U5  
**UI:** `https://192.168.1.254:21443/external.html`

## Default posture
Knots RPC (`21.21.21.21:8332`) is **not** reachable from the LAN or WAN.  
Appliance wallet UI talks to RPC from the router host only.

## Explicit enable (LAN DNAT)
1. Open **External apps** on the node UI → **Enable LAN RPC**.
2. First enable installs `rpcauth` + `rpcallowip=192.168.1.0/24` and may **restart bitcoind** once.
3. Firewall: LAN DNAT `192.168.1.254:8332` → `21.21.21.21:8332` (disabled by default).
4. WAN `:8332` remains **REJECT**.
5. **Disable** when finished (closes LAN path; credentials kept for next enable).

CLI on device:
```sh
/usr/libexec/knots/external-rpc.sh status|enable|disable|rotate
```

## Supported apps (AS_BUILT lock)

| App | Status | Method |
|-----|--------|--------|
| **Sparrow** | **Primary — tested path** | Bitcoin Core RPC → `192.168.1.254:8332` + rpcauth user/pass |
| **Specter** | Documented | Same RPC endpoint |
| **BlueWallet** | Limited | No Electrum server in P2B-B; not the primary path |

### Sparrow
- Settings → Server → **Bitcoin Core**
- Host `192.168.1.254`, port `8332`, user/password from External apps page
- Optional Core wallet name: `appliance`

### Specter
- Add Bitcoin Core / remote node with the same host, port, user, password

### BlueWallet
BlueWallet’s usual full-node path expects Electrum. This stage does **not** ship Electrum/Fulcrum. Prefer Sparrow/Specter against this appliance for P2B-B.

## SSH tunnel (advanced, no LAN DNAT)
From a PC on the LAN (requires SSH to the router — production WAN SSH stays locked):
```sh
ssh -N -L 8332:21.21.21.21:8332 root@192.168.1.254
```
Then point the app at `127.0.0.1:8332` with cookie or rpcauth. Prefer the UI enable path for non-experts.
