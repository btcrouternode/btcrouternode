# btcrouternode

**A home internet router that is also a Bitcoin full node.** Open-source
firmware for the Banana Pi BPI-R4, built on **OpenWrt**, running **Bitcoin
Core** by default — your router keeps a full copy of the Bitcoin blockchain and
verifies it itself. (Inside the firmware the device still calls itself
*RNode*: Wi-Fi `rnode`, address `http://rnode-xxxx.local`.)

- Router: Wi-Fi, firewall, internet (OpenWrt 24.10)
- Node: Bitcoin Core (default) or Bitcoin Knots — your choice, each installed
  only after checking its own project's release signatures
- Setup from a laptop or computer, with a secure (HTTPS) connection to the router
- Updates only from releases signed by the maintainers

**Release 1:** `24.10.8.29.3.118` — see [Releases](../../releases) for the
image, its SHA256 and signatures.

## Building it yourself

On a Linux PC (Debian / Ubuntu):

```bash
make image          # test build, signed with your own test key
make test-host      # the host test suite
```

A test build is signed with **your** test key (`keys/test/`), so routers
running official releases do not accept it through Settings — install your own
build over the serial console or from an SD card instead (see `NOTICE.md`,
"Installing your own build"). Official releases are built with
`make image RELEASE=1` and signed offline by a maintainer
([docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)).

## How the project works

Like Bitcoin Core: anyone can fork and propose changes; the maintainers review
and merge; every merge and release tag is signed with a maintainer's PGP key;
release builds are confirmed by their builders in
[btcrouternode.sigs](https://github.com/btcrouternode/btcrouternode.sigs).

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to propose changes
- [SECURITY.md](SECURITY.md) — reporting a security problem
- [MAINTAINERS.md](MAINTAINERS.md) — who merges and signs, and their keys
- [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md) — how releases are made and checked

## Licence

GPL-2.0-only, the same as OpenWrt — see [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md) (other components keep their own licences).

Stewarded by [Fiftyone-Percent](https://fiftyone-percent.net), which also builds
the hardware units. Project site: [btcrouternode.org](https://btcrouternode.org).
