# Security

## Reporting a problem

Please **do not** open a public issue for a security problem.

- **Preferred:** GitHub → this repository → **Security** → **Report a vulnerability**
  (private to the maintainers).
- **Or email**, encrypted with the PGP key below if you can:
  Eugene <eugene@fiftyone-percent.net>.

You will get an answer within a few days. Please give us reasonable time to fix
it before telling anyone else.

## Keys

Check releases and signatures against these fingerprints — and against the
same list on [btcrouternode.org](https://btcrouternode.org), which is published
separately from GitHub.

| Who | PGP key (merges, tags, signed fingerprints) | Firmware key (routers check it) |
|-----|---------------------------------------------|----------------------------------|
| Eugene | `5271 52B5 9BFA 6688 43A4  30A6 06D0 406C 5CF2 4C42` ([key](keys/maintainers/eugene.asc)) | `2e51b93dd6058ffb` ([signed by his PGP key](keys/maintainers/eugene-firmware-key-2e51b93dd6058ffb.asc)) |

Release 1 (`24.10.8.29.3.118`) also trusts the standby firmware key
`833eb2b299741478`; it is retired in the next release (one firmware key per
maintainer, [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)).

Official release images are signed offline. Routers accept updates through
Settings only when signed by a maintainer's firmware key.
