# Release signing — public keys

Only PUBLIC usign keys live here. Secret keys never enter this repository
(`*.sec` is gitignored; `tests/host/test-release-sig.sh` fails if one is tracked).

| Folder | Key | Fingerprint | Secret kept |
|---|---|---|---|
| `release/` | **Eugene's firmware key** — signs releases | `2e51b93dd6058ffb` | his encrypted sticks (primary + backup), offline only |
| `release/` | **Standby (retired)** — trusted by Release 1 only, removed in the next release | `833eb2b299741478` | Eugene's backup stick, marked retired |
| `test/` | **TEST** — your own test builds | `2df2b26d922dc8b1` | the build PC (`~/.config/rnode/test-key/`); make your own for your builds |
| `maintainers/` | Maintainers' **PGP** public keys and `trusted-keys` (merges / tags on `main`); each firmware key signed by its maintainer's PGP key | see `MAINTAINERS.md` | each maintainer's own sticks |

One firmware key per maintainer, made offline with `factory/offline/rnode-offline.sh`
(option 3, "maintainer identity") — `docs/RELEASE_PROCESS.md` §3.

`make overlay` copies them into `files/etc/knots/release-keys/`, which every
router trusts for Settings upgrades (`build/stage-release-keys.sh`):

- **test build** (default `make image`): the maintainers' firmware keys + TEST;
  the image is signed with the TEST key automatically.
- **release build** (`make image RELEASE=1`): the maintainers' firmware keys
  only, left unsigned; a maintainer signs it offline.

A router running a release build accepts only maintainer-signed upgrades through
Settings; any other build goes on over the serial console or an SD card
(`NOTICE.md`, "Installing your own build").
