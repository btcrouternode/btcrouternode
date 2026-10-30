#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Checks that main is the history the maintainers signed (after Bitcoin Core's
# contrib/verify-commits):
#  - every commit on the first-parent line from the given commit back to
#    trusted-git-root is PGP-signed by a key in keys/maintainers/trusted-keys
#    as that file stood in the commit's parent — so adding a maintainer takes
#    a commit signed by an existing one;
#  - merge commits add no changes of their own (unless listed in
#    allow-unclean-merge-commits);
#  - every release tag (v*) is an annotated tag signed by a key trusted at the
#    commit it tags.
# Contributors' commits inside a merge need no PGP signature; their
# Signed-off-by is checked on the pull request (DCO) and by contrib/merge-pr.sh.
# Public keys come from keys/maintainers/*.asc in the history itself.
# Usage: contrib/verify-commits/verify-commits.sh [commit]   (default HEAD)
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
TIP=$(git rev-parse --verify "${1:-HEAD}^{commit}")
ROOT=$(sed 's/#.*//' "$DIR/trusted-git-root" | awk 'NF { print $1; exit }')
ALLOW=$(sed 's/#.*//' "$DIR/allow-unclean-merge-commits" | awk 'NF { print $1 }')

G=$(mktemp -d); export GNUPGHOME="$G"
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$G"' EXIT
chmod 700 "$G"
errors=0
bad() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

git cat-file -e "$ROOT^{commit}" 2>/dev/null || { echo "FAIL: trusted root $ROOT is not in this repository" >&2; exit 1; }
git merge-base --is-ancestor "$ROOT" "$TIP" || { echo "FAIL: $TIP does not descend from the trusted root $ROOT" >&2; exit 1; }

# Public keys and trusted fingerprints as they stood in commit $1.
imported=" "
import_keys() {
	git ls-tree "$1" keys/maintainers/ | while read -r _ type blob path; do
		[ "$type" = blob ] && case "$path" in *.asc) echo "$blob" ;; esac
	done >"$G/blobs"
	while read -r blob; do
		case "$imported" in *" $blob "*) continue ;; esac
		git cat-file blob "$blob" | gpg --batch --quiet --import 2>/dev/null || true
		imported="$imported$blob "
	done <"$G/blobs"
}
trusted() {	# trusted <commit> <primary fingerprint> → prints the name
	git show "$1:keys/maintainers/trusted-keys" 2>/dev/null | sed 's/#.*//' |
		awk -v f="$2" 'toupper($1) == toupper(f) && f != "" { $1 = ""; sub(/^ /, ""); print ($0 == "" ? f : $0); found = 1; exit }
			END { exit !found }'
}

# --- commits on main's first-parent line --------------------------------------
n=0; oldest=
for c in $(git rev-list --first-parent "$ROOT..$TIP"); do
	n=$((n + 1)); oldest=$c
	parent=$(git rev-parse "$c^1")
	import_keys "$parent"
	subject=$(git log -1 --format=%s "$c")
	IFS='|' read -r st primary sub <<EOF
$(git -c gpg.program=gpg log -1 --format='%G?|%GP|%GF' "$c" 2>/dev/null)
EOF
	[ -n "$primary" ] || primary=$sub
	case "$st" in
		G | U | Y) ;;	# good signature (Y: by a key that has since expired)
		N) bad "$c is not signed: $subject"; continue ;;
		E) bad "$c is signed by a key not in keys/maintainers/: $subject"; continue ;;
		*) bad "$c has a bad or revoked signature ($st): $subject"; continue ;;
	esac
	if ! who=$(trusted "$parent" "$primary"); then
		bad "$c is signed by $primary, which is not in keys/maintainers/trusted-keys: $subject"
		continue
	fi
	if [ "$(git rev-list --no-walk --parents "$c" | wc -w)" -gt 2 ]; then
		if [ -n "$(git -c core.quotepath=off show --no-ext-diff --no-color --cc --format= "$c")" ] &&
			! printf '%s\n' "$ALLOW" | grep -qx "$c"; then
			bad "merge $c (signed by $who) adds changes of its own: $subject"
		fi
	fi
done
if [ -n "$oldest" ] && [ "$(git rev-parse "$oldest^1")" != "$ROOT" ]; then
	bad "main's first-parent line does not reach the trusted root $ROOT"
fi

# --- release tags --------------------------------------------------------------
t=0
for tag in $(git for-each-ref --format='%(refname:strip=2)' 'refs/tags/v*'); do
	commit=$(git rev-parse "$tag^{commit}")
	git merge-base --is-ancestor "$ROOT" "$commit" || continue	# older than the public history
	t=$((t + 1))
	if [ "$(git cat-file -t "refs/tags/$tag")" != tag ]; then
		bad "tag $tag is not an annotated (signed) tag"; continue
	fi
	import_keys "$commit"
	raw=$(git -c gpg.program=gpg verify-tag --raw "$tag" 2>&1 || true)
	if ! printf '%s\n' "$raw" | grep -Eq '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) '; then
		bad "tag $tag has no good signature"; continue
	fi
	primary=$(printf '%s\n' "$raw" | awk '$2 == "VALIDSIG" { print $NF; exit }')
	trusted "$commit" "$primary" >/dev/null || bad "tag $tag is signed by $primary, which is not in keys/maintainers/trusted-keys"
done

if [ "$errors" -gt 0 ]; then
	echo "verify-commits: $errors problem(s) — main or a release tag is not what the maintainers signed" >&2
	exit 1
fi
echo "verify-commits: OK — $n commit(s) after $(git rev-parse --short "$ROOT") up to $(git rev-parse --short "$TIP") and $t release tag(s) signed by maintainers"
