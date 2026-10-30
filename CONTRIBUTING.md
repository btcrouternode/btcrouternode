# Contributing

Anyone can contribute. The way of working follows Bitcoin Core and OpenWrt
([docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)).

## Proposing a change

1. **Fork** this repository and make a branch.
2. Keep **one logical change per commit** (a fix and a feature are two commits),
   with a short subject in the imperative ("Fix …", "Add …") and a body that
   says *why*.
3. **Sign off every commit** — `git commit -s` adds
   `Signed-off-by: Your Name <you@example.org>`, your statement under the
   [Developer Certificate of Origin 1.1](https://developercertificate.org/)
   that you have the right to contribute it under this project's licence
   (GPL-2.0-only). Commits without it cannot be merged.
4. Run the tests: `make test-host` (and the device tests in `tests/device/` if
   your change touches the router and you have one).
5. Open a **pull request** against `main` and describe what you tested.

You do not need to sign your commits with PGP — the maintainers sign the merge.

## Review

Review happens in public on the pull request. Say what you checked:

- **Concept ACK** — agree with the idea
- **ACK** (with the commit) — reviewed the code and agree
- **tested ACK** — reviewed and tested it (say how / on what hardware)
- **NACK** — disagree, with the reason

## Merging

Only the [maintainers](MAINTAINERS.md) merge. They merge on their own
computer with a **PGP-signed merge commit** and push it; `main` takes no other
pushes. Every merge on `main` must be signed by a key in
`keys/maintainers/trusted-keys`.

## Not in this repository

- No secret keys, ever (`*.sec` is refused by the tests).
- The manufacturer's factory key and factory data (sticker passwords,
  inventory) are not part of the project.
