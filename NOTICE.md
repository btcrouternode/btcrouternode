# Licence and notices

## This project

RNode — the firmware scripts, web pages and Setup, the factory station,
sticker and recovery tools, the build and offline signing tools, and the tests
— is free software under the **GNU General Public License, version 2 only**
(`GPL-2.0-only`), the same licence as OpenWrt. The full text is in
[`LICENSE`](LICENSE). Each file says so in its first lines
(`SPDX-License-Identifier: GPL-2.0-only`); files without such a line (data,
translations, documentation) are under the same licence.

Anyone who passes this software on — as a download or on a device, changed or
unchanged, sold or free — must pass on its complete source code under the same
licence (GPL-2.0, sections 1–3).

### Files under another licence

| File | From | Licence |
|------|------|---------|
| `files/etc/knots/overlay-ui/sysauth.ut`, `files/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut` | LuCI (login page, changed) | Apache-2.0 (notice in the file) |
| `files/etc/rc.button/reset`, `files/etc/banner` | OpenWrt base-files (changed) | GPL-2.0, as OpenWrt |

## What the firmware contains (not part of this project)

The firmware image is built with the OpenWrt Image Builder and carries other
projects' software, each under its own licence:

| Component | Licence | Source |
|-----------|---------|--------|
| OpenWrt 24.10 (Linux kernel, BusyBox, packages in `build/packages.txt`) | GPL-2.0 and others (per package) | https://github.com/openwrt/openwrt (tag `v24.10.8`) and the OpenWrt package feeds; licences per package in the build |
| Bitcoin Core 29.4 | MIT | https://github.com/bitcoin/bitcoin |
| Bitcoin Knots 29.3 (`v29.3.knots20260507`) | MIT | https://github.com/bitcoinknots/bitcoin |
| LXC | LGPL-2.1+ / GPL-2.0 | https://github.com/lxc/lxc |
| Debian packages inside the node container | per package (`/usr/share/doc/*/copyright` in the container) | https://www.debian.org/ |
| LuCI | Apache-2.0 | https://github.com/openwrt/luci |

When routers or firmware are distributed, the corresponding source of the
GPL-licensed components must be offered with them (GPL-2.0 section 3) — for
OpenWrt: the exact OpenWrt release and package versions used, as listed by the
Image Builder for that build.

## Installing your own build

Routers sold with RNode only accept **signed** updates through Settings. That
does not lock owners out: the router can always be installed with **any**
build — including one you made from this source with `make image` — over the
serial console (U-Boot + TFTP, `factory/PRODUCTION.md`) or from an SD card
(`docs/FACTORY_EMMC_INSTALL.md`). The blockchain on the M.2 is not touched.
