# RNode release keys A and B — offline generation

> **Use the script (2026-10-27).** The build PC stages `~/rnode-sign/` on the
> build laptop (`make offline-stage MODE=keys|sign STATION=…`) and gives you the
> **tools fingerprint** for your paper. In the live session:
>
> 1. **Files** → **Other Locations** → click the laptop's own drive (about
>    **127 GB**, not the 2 TB one) so it opens.
> 2. **Terminal** (Ctrl + Alt + T), two lines:
>
> ```bash
> sudo -i
> cd /run/media/*/*/home/*/rnode-sign/rnode-keygen && sha256sum SHA256SUMS && sha256sum -c --quiet SHA256SUMS && bash rnode-offline.sh
> ```
>
>    The first number printed must be the tools fingerprint on your paper
>    (otherwise press Ctrl + C). The script then shows a menu — **1** new keys
>    A and B, **2** sign the release — finds each key stick itself, checks every
>    step (the key file is really on the stick, the release fingerprint, the key
>    is one built into the release, the signature verifies like the router) and
>    asks only for clicks in Disks, Enter and **y**. Write down what it shows.
>
> The manual steps below are the same work by hand (background / fallback).
> Note: this live system opens drives under `/run/media/<user>/`, not `/media/`.

Key **A** signs every release. Key **B** is the standby: firmware trusts both,
so if A is ever lost or exposed, releases are signed with B and A is removed
in the next build. Each secret lives only on its own encrypted USB stick and
never touches a networked computer.

You need:

- the offline laptop, booted from a 64-bit Linux live USB (e.g. Ubuntu →
  **Try Ubuntu**), no network cable, Wi‑Fi off
- the offline tools: `make offline-tools` writes them to
  `bin/offline-tools/rnode-keygen/` in the project folder (that folder is
  the master copy); carry it to the offline laptop however you choose — it
  never holds a secret
- two new sticks, **KEY A** and **KEY B** (all data on them is erased)
- pen and paper, including the SHA256 printed when the tools stick was made

Use **one Terminal window** for everything (it remembers `$T`).

## 1. Load and check the tools

The tools may be on the Ubuntu live stick itself (it then shows as `/cdrom`)
or on a separate stick. If separate, plug it in now. Open **Terminal**:

```bash
T=$(ls -d /media/$USER/*/rnode-keygen /cdrom/rnode-keygen 2>/dev/null | head -1); echo "$T"
case "$T" in /cdrom/*) sudo mount -o remount,rw /cdrom ;; esac
cp -r "$T" /tmp/ && cd /tmp/rnode-keygen
sha256sum SHA256SUMS
sha256sum -c SHA256SUMS
chmod +x *.sh usign/bin/* usign/bin/.*.bin usign/lib/ld-linux-x86-64.so.2
```

- `echo` must show a path ending in `rnode-keygen`. If you copied the folder
  somewhere else (e.g. the Desktop), use `T=~/Desktop/rnode-keygen` instead. (On the live stick the
  `remount` lets the two public keys be saved back to it at the end.)
- The first SHA256 must match the one on your paper; every line after must say `OK`.
- (Tools are copied into memory because live systems often refuse to run
  programs straight from a USB stick.)

## 2. Encrypt key stick A

1. Plug in **KEY A** (leave the tools stick in).
2. Open **Disks**. Select the KEY A stick — check the size; it is *not* the
   live USB or the tools stick. ⋮ menu → **Format Disk…** → **Format**.
3. Click **+** → full size → **Next** → Volume Name `RNODE-KEY-A`, Type
   **Internal disk for use with Linux systems only (Ext4)**, tick
   **Password protect volume (LUKS)** → **Next** → a strong passphrase
   (write it down, labelled "A") → **Create**.
4. Click ▶ (mount) and enter the passphrase. It opens at
   `/media/<you>/RNODE-KEY-A`.

## 3. Generate key A onto stick A

```bash
sudo ./release-keygen.sh /media/$USER/RNODE-KEY-A/release-key A "$T/public"
```

It must say **self-test passed** and print a **PUBLIC fingerprint** (16
letters/digits). Write it down next to "A".

In Disks: ■ (unmount), then 🔒 (lock). Unplug KEY A.

## 4. Key stick B

Repeat step 2 with `RNODE-KEY-B` and a **different** passphrase (labelled
"B"), then:

```bash
sudo ./release-keygen.sh /media/$USER/RNODE-KEY-B/release-key B "$T/public"
```

Write down fingerprint B. Unmount, lock and unplug KEY B.

## 5. Finish

```bash
ls -l "$T/public/"
ls -R "$T" | grep -c '\.sec$'
```

- `public/` holds exactly two files, named with fingerprints A and B.
- The second command must print `0` (no secret on the tools stick).

Eject the tools stick in Files (if it is a separate stick), then shut the laptop down — the live session
keeps nothing.

## Storing them

- KEY A and KEY B in **different places** (e.g. home safe and a bank box).
- Each passphrase is stored apart from its stick.
- The paper with the two fingerprints stays with the owner: it is how to check
  later that the public keys in the firmware are really yours.
- The two files in `public/` are not secret: they go into
  `files/etc/knots/release-keys/` in the repository.

---

# Signing a release with key A (each release)

Build with `make image RELEASE=1` on the build PC (A + B only, unsigned), then
copy the `.itb` named in the build output into `rnode-keygen/` on the tools stick.

On the offline laptop (live USB, no network), load the tools as in step 1, then:

1. Plug in KEY A and unlock it in **Disks** (▶, passphrase A).
2. Sign (the image is changed in place, on the laptop's copy):

```bash
cp "$T"/*.itb /tmp/rnode-keygen/
sudo ./sign-image.sh /media/$USER/RNODE-KEY-A/release-key/rnode-release-A.sec /tmp/rnode-keygen/*.itb
cp /tmp/rnode-keygen/*.itb "$T/"
```

   It prints `Signed … with key 2e51b93dd6058ffb` and the new SHA256 —
   write the SHA256 down; it is the one published for the release.
3. Unmount and lock KEY A in Disks, unplug it, shut down.

Back on the build PC, put the signed `.itb` in the project folder (e.g.
`bin/offline-tools/signed/`) and file the release next to the builds:

```bash
make store-release SIGNED=bin/offline-tools/signed/<image>.itb
```

It checks the signature is from key A or B (not TEST), that it is this
`RELEASE=1` build, and stores it read-only in
`bin/targets/mediatek/filogic/Releases/<version>/` with its SHA256 list and
the signing key (`make image` never deletes `Releases/`). The SHA256 it prints
must match the one written down in step 2. If KEY A is ever lost or
exposed, sign with KEY B instead (`RNODE-KEY-B/release-key/rnode-release-B.sec`)
and remove A from `keys/release/` in the next build.

## Same laptop as the build/station laptop (no carry stick)

The build/station laptop can be the offline laptop: started from the live USB,
its own Ubuntu is not running and nothing is on the network. The build PC puts
a folder `~/rnode-sign/` on its drive (`unsigned/` the release, `rnode-keygen/`
the tools, `signed/` empty); the live session reads and writes it directly.

Two values from the build PC go on paper first: the **tools** SHA256
(`sha256sum SHA256SUMS`) and the **unsigned release** SHA256. Checking both in
the live session proves nothing on the networked laptop changed them.

1. Shut the laptop down. Unplug the network cable. Start from the live USB →
   **Try Ubuntu**; Wi‑Fi off.
2. **Terminal** — open the laptop's own Ubuntu drive by its ID (Files may open
   the other drive, and the live user may not see into `/home/<user>`, so
   everything reading it uses `sudo`). Find the station drive's ID with
   `lsblk -f` on its normal system and put it in place of `<DRIVE-UUID>`:

```bash
sudo mkdir -p /mnt/station && sudo mount UUID=<DRIVE-UUID> /mnt/station
S=$(sudo find /mnt/station/home -maxdepth 2 -type d -name rnode-sign | head -1); echo "$S"
sudo ls -la "$S/unsigned"
```

3. Copy the tools and the release into memory and check both:

```bash
sudo cp -r "$S/rnode-keygen" /tmp/ && sudo chown -R $USER /tmp/rnode-keygen && cd /tmp/rnode-keygen
sha256sum SHA256SUMS
sha256sum -c SHA256SUMS
chmod +x *.sh usign/bin/* usign/bin/.*.bin usign/lib/ld-linux-x86-64.so.2
sudo cp "$S"/unsigned/*.itb /tmp/rnode-keygen/ && sudo chown $USER /tmp/rnode-keygen/*.itb
sha256sum /tmp/rnode-keygen/*.itb
```

   `echo` shows a path ending in `rnode-sign`; the first SHA256 = the tools
   value on paper, every check says `OK`; the last SHA256 = the **unsigned
   release** value on paper. Any difference: stop, do not sign.
4. Plug in **KEY A**, unlock it in **Disks** (▶, passphrase A), then:

```bash
sudo ./sign-image.sh /media/$USER/RNODE-KEY-A/release-key/rnode-release-A.sec /tmp/rnode-keygen/*.itb
sudo cp /tmp/rnode-keygen/*.itb "$S/signed/" && sudo chown 1000:1000 "$S"/signed/*.itb
```

   It prints `Signed … with key 2e51b93dd6058ffb` and the **signed** SHA256 —
   write that down.
5. `sudo umount /mnt/station`. In **Disks**: unmount and lock KEY A, unplug it.
   Shut down, remove the live USB, plug the network back in, start normally.

Then on the build PC: `make store-release SIGNED=<copy of ~/rnode-sign/signed/….itb>`
— the SHA256 it prints must equal the signed value on paper.
