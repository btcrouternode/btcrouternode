# Maintainers

Maintainers review and merge changes, sign merges and release tags with their
PGP key, and sign release images offline with their own firmware key
([docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)). Each maintainer looks
after their own keys; there is no shared project key.

| Name | Role | PGP fingerprint | Firmware key |
|------|------|-----------------|--------------|
| Eugene | Lead maintainer (Fiftyone-Percent) | `527152B59BFA668843A430A606D0406C5CF24C42` | `2e51b93dd6058ffb` |
| *(second maintainer — joining)* | Maintainer | — | — |

- Public PGP keys: `keys/maintainers/<name>.asc`
- Fingerprints checked on `main`: `keys/maintainers/trusted-keys`
- Firmware public keys built into releases: `keys/release/<fingerprint>`

**Joining or leaving:** a new maintainer is added by a pull request signed by
an existing maintainer (their public key, fingerprint and firmware key); their
firmware key is trusted by routers only from the next signed release. A
maintainer who leaves, or whose key is lost, is removed the same way.
