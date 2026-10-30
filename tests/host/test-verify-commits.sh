#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# T-VERIFY-COMMITS: contrib/verify-commits accepts main only when every
# first-parent commit is signed by a key trusted in its parent, merges add
# nothing of their own and release tags are signed; contrib/merge-pr.sh refuses
# a pull request without Signed-off-by, and merges + signs + pushes a good one.
# Throw-away keys and repositories only.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
export GNUPGHOME="$W/gnupg"
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v gpg >/dev/null || { echo "SKIP: no gpg"; exit 0; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_DATE=2026-10-30T00:00:00Z
mkdir -m 700 "$GNUPGHOME"
key() {	# key <name> → fingerprint
	gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@example.org>" ed25519 sign never 2>/dev/null
	gpg --list-keys --with-colons "$1@example.org" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}
M=$(key maint); X=$(key outsider); M2=$(key second)

V="$W/vc/contrib/verify-commits/verify-commits.sh"
mkdir -p "$W/vc/contrib" && cp -r "$ROOT/contrib/verify-commits" "$W/vc/contrib/"
verify() { (cd "$W/repo" && "$V" "${1:-HEAD}") >"$W/out" 2>&1; }
ok() { verify "${2:-HEAD}" || fail "$1: $(cat "$W/out")"; pass "$1"; }
refused() { if verify "${3:-HEAD}"; then fail "$1 must be refused"; fi; grep -q "$2" "$W/out" || fail "$1: expected '$2' in: $(cat "$W/out")"; pass "$1 refused"; }

git init -q -b main "$W/repo"; cd "$W/repo"
git config user.name maint; git config user.email maint@example.org; git config user.signingkey "$M"
mkdir -p keys/maintainers contrib
gpg --armor --export "$M" >keys/maintainers/maint.asc
echo "$M maint" >keys/maintainers/trusted-keys
echo one >file; git add -A; git commit -q -S -m root
echo "$(git rev-parse HEAD)" >"$W/vc/contrib/verify-commits/trusted-git-root"
: >"$W/vc/contrib/verify-commits/allow-unclean-merge-commits"
ok "nothing after the trusted root"

echo two >>file; git commit -q -S -am "signed by a maintainer"
ok "commit signed by a maintainer"

git checkout -q -b pr; git -c user.name=contrib -c user.email=c@example.org commit -q --allow-empty -m "contributor (unsigned)"
git checkout -q main; git merge -q --no-ff -S -m "Merge #1: contributor" pr
ok "signed merge of an unsigned contributor commit"
GOOD=$(git rev-parse HEAD)

echo three >>file; git commit -q -am "unsigned"
refused "unsigned commit on main" "is not signed"
git reset -q --hard "$GOOD"

echo three >>file; git commit -q -S"$X" -am "outsider"
refused "commit by an untrusted key" "is signed by a key not in keys/maintainers"
git reset -q --hard "$GOOD"

gpg --armor --export "$X" >keys/maintainers/outsider.asc; echo "$X outsider" >>keys/maintainers/trusted-keys
git add -A; git commit -q -S"$X" -m "outsider adds itself"
refused "an outsider adding its own key" "is signed by a key not in keys/maintainers"
git reset -q --hard "$GOOD"

gpg --armor --export "$M2" >keys/maintainers/second.asc; echo "$M2 second" >>keys/maintainers/trusted-keys
git add -A; git commit -q -S -m "add the second maintainer"
echo four >>file; git commit -q -S"$M2" -am "by the second maintainer"
ok "a maintainer added by an existing one can sign"
GOOD=$(git rev-parse HEAD)

git checkout -q -b pr2 "$GOOD~1"; git -c user.name=contrib -c user.email=c@example.org commit -q --allow-empty -m "contributor 2"
git checkout -q main; git merge -q --no-ff --no-commit pr2 >/dev/null; echo sneaky >>file; git add file
git commit -q -S -m "Merge #2: with a hidden change"
refused "merge with a change of its own" "adds changes of its own"
git rev-parse HEAD >"$W/vc/contrib/verify-commits/allow-unclean-merge-commits"
ok "allowed unclean merge"
: >"$W/vc/contrib/verify-commits/allow-unclean-merge-commits"
git reset -q --hard "$GOOD"

git tag -s -m v1 v1.0 "$GOOD"; ok "signed release tag"
git tag v1.1 "$GOOD"; refused "lightweight release tag" "not an annotated"
git tag -d v1.1 >/dev/null; git tag -a -m v1.2 v1.2 "$GOOD"; refused "unsigned release tag" "has no good signature"
git tag -d v1.2 >/dev/null; git tag -d v1.0 >/dev/null

# --- merge-pr.sh -----------------------------------------------------------------
cp -r "$W/vc/contrib/verify-commits" contrib/ && cp "$ROOT/contrib/merge-pr.sh" contrib/
git add -A; git commit -q -S -m "add the merge tools"
git init -q --bare "$W/origin.git"; git remote add origin "$W/origin.git"; git push -q origin main
api="$W/api/repos/o/r"; mkdir -p "$api/pulls" "$api/issues/3"
pr() {	# pr <n> <with sign-off: yes|no> — a contributor's pull request on origin + its API answer
	git checkout -q -b "c$1" main
	echo "pr $1" >"pr$1"; git add "pr$1"
	if [ "$2" = yes ]; then
		git -c user.name=contrib -c user.email=c@example.org commit -q -s -m "Add pr$1"
	else
		git -c user.name=contrib -c user.email=c@example.org commit -q -m "Add pr$1"
	fi
	git push -q origin "c$1:refs/pull/$1/head"
	printf '{"state":"open","base":{"ref":"main"},"head":{"sha":"%s"},"title":"Add pr%s","user":{"login":"contrib"},"body":"Adds pr%s."}' \
		"$(git rev-parse HEAD)" "$1" "$1" >"$api/pulls/$1"
	git checkout -q main; git branch -q -D "c$1"
}
export MERGE_PR_API="file://$W/api" MERGE_PR_REPO=o/r
MP=contrib/merge-pr.sh

pr 4 no
if echo y | $MP 4 --no-test >"$W/out" 2>&1; then fail "merge-pr must refuse a commit without Signed-off-by"; fi
grep -q "without a matching Signed-off-by" "$W/out" || fail "merge-pr no sign-off: $(cat "$W/out")"
[ "$(git symbolic-ref --short HEAD)" = main ] && [ -z "$(git branch --list 'merge-pr/*')" ] || fail "merge-pr left a branch behind"
pass "merge-pr refuses a pull request without Signed-off-by"

pr 3 yes
printf '[{"user":{"login":"rev"},"body":"tested ACK %s\\nworks on my router"}]' "$(git rev-parse --short refs/remotes/origin/main)" >"$api/issues/3/comments"
before=$(git rev-parse origin/main)
printf 's\nn\n' | $MP 3 --no-test >"$W/out" 2>&1 && fail "merge-pr pushed although told not to"
[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$before" ] || fail "origin main changed after 'n'"
pass "merge-pr pushes nothing unless told to"

printf 's\ny\n' | $MP 3 --no-test >"$W/out" 2>&1 || fail "merge-pr: $(cat "$W/out")"
tip=$(git ls-remote origin refs/heads/main | cut -f1)
[ "$tip" = "$(git rev-parse HEAD)" ] && [ "$(git rev-parse HEAD^2)" = "$(git ls-remote origin refs/pull/3/head | cut -f1)" ] ||
	fail "origin main is not the merge of pull request 3"
git log -1 --format=%B | grep -q "^Merge #3: Add pr3" || fail "merge message title: $(git log -1 --format=%B)"
git log -1 --format=%B | grep -q "tested ACK" || fail "merge message must list the ACK"
[ "$(git log -1 --format=%G?)" = G ] || [ "$(git log -1 --format=%G?)" = U ] || fail "merge is not signed"
ok "main after merge-pr"
pass "merge-pr merges, signs and pushes a good pull request"
echo "ALL PASS: test-verify-commits"
