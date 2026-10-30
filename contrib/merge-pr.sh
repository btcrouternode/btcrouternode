#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Merges a pull request into main the way the maintainers do it (after Bitcoin
# Core's github-merge.py): on your own computer, with a merge commit signed by
# your PGP key, pushed over SSH.
#
#   contrib/merge-pr.sh <pull request number> [--no-test]
#
#  1. fetches main and the pull request from origin;
#  2. refuses it unless every commit carries a Signed-off-by line matching its
#     author (DCO) and nothing looks like a secret key;
#  3. merges it on a temporary branch ("Merge #N: title", the commits, the
#     description and the reviewers' ACKs) and runs the tests (make test-host);
#  4. shows you the result — you sign it (your PGP passphrase is asked here);
#  5. checks it with contrib/verify-commits as it was on main before the merge,
#     then pushes to main when you say so. GitHub marks the pull request merged.
#
# Settings (environment): MERGE_PR_REMOTE (origin), MERGE_PR_REPO (owner/repo,
# default from the remote's URL), MERGE_PR_TESTCMD (make test-host),
# MERGE_PR_API (https://api.github.com).
set -eu
N=${1:-}; TEST=1
[ "${2:-}" = --no-test ] && TEST=0
case "$N" in '' | *[!0-9]*) echo "usage: contrib/merge-pr.sh <pull request number> [--no-test]" >&2; exit 2 ;; esac
REMOTE=${MERGE_PR_REMOTE:-origin}
API=${MERGE_PR_API:-https://api.github.com}
TESTCMD=${MERGE_PR_TESTCMD:-make test-host}
die() { echo "merge-pr: $*" >&2; exit 1; }
ask() { printf '%s ' "$1" >&2; read -r ans || ans=; }

cd "$(git rev-parse --show-toplevel)"
[ "$(git symbolic-ref --short -q HEAD)" = main ] || die "switch to main first"
git diff --quiet && git diff --cached --quiet || die "commit or stash your local changes first"
REPO=${MERGE_PR_REPO:-$(git remote get-url "$REMOTE" | sed -E 's#^(git@|ssh://git@|https://)github\.com[:/]##; s#\.git$##')}
case "$REPO" in */*) ;; *) die "cannot tell the GitHub repository from remote '$REMOTE' (set MERGE_PR_REPO=owner/repo)" ;; esac
if t=$(tty 2>/dev/null); then export GPG_TTY="$t"; fi

# --- 1. fetch ------------------------------------------------------------------
git fetch -q "$REMOTE" "+refs/heads/main:refs/merge-pr/$N/base" "+refs/pull/$N/head:refs/merge-pr/$N/head" ||
	die "could not fetch pull request #$N from $REMOTE"
BASE=$(git rev-parse "refs/merge-pr/$N/base"); HEAD_C=$(git rev-parse "refs/merge-pr/$N/head")
[ "$(git rev-parse main)" = "$BASE" ] || die "your main is not $REMOTE's main — run: git pull --ff-only $REMOTE main"

W=$(mktemp -d); BR="merge-pr/$N"
cleanup() {
	[ "$(git symbolic-ref --short -q HEAD)" = "$BR" ] && { git merge --abort 2>/dev/null || true; git checkout -q -f main; }
	git branch -q -D "$BR" 2>/dev/null || true
	git update-ref -d "refs/merge-pr/$N/base" 2>/dev/null || true
	git update-ref -d "refs/merge-pr/$N/head" 2>/dev/null || true
	rm -rf "$W"
}
trap cleanup EXIT

# The pull request's title, description and reviews (public API, no login).
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$W/$1"; }
curl -fsS "$API/repos/$REPO/pulls/$N" -o "$W/pr.json" || die "could not read pull request #$N from GitHub"
curl -fsS "$API/repos/$REPO/issues/$N/comments?per_page=100" -o "$W/comments.json" 2>/dev/null || echo '[]' >"$W/comments.json"
curl -fsS "$API/repos/$REPO/pulls/$N/reviews?per_page=100" -o "$W/reviews.json" 2>/dev/null || echo '[]' >"$W/reviews.json"
[ "$(json pr.json 'd["state"]')" = open ] || die "pull request #$N is not open"
[ "$(json pr.json 'd["base"]["ref"]')" = main ] || die "pull request #$N is not for main"
[ "$(json pr.json 'd["head"]["sha"]')" = "$HEAD_C" ] || die "pull request #$N changed while fetching — run again"
TITLE=$(json pr.json 'd["title"].strip()')
AUTHOR=$(json pr.json 'd["user"]["login"]')

# --- 2. checks -----------------------------------------------------------------
[ -n "$(git rev-list "$BASE..$HEAD_C")" ] || die "pull request #$N has nothing new for main"
problems=0
for c in $(git rev-list --reverse "$BASE..$HEAD_C"); do
	email=$(git log -1 --format=%ae "$c")
	if ! git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$c" | grep -qiF "<$email>"; then
		echo "  no Signed-off-by for $email: $(git log -1 --format='%h %s' "$c")" >&2; problems=$((problems + 1))
	fi
done
[ "$problems" = 0 ] || die "$problems commit(s) without a matching Signed-off-by — ask the author to use git commit -s (see CONTRIBUTING.md)"
if git diff --name-only "$BASE...$HEAD_C" | grep -Eq '\.sec$' ||
	git diff "$BASE...$HEAD_C" | grep -Eq '^\+.*(BEGIN [A-Z ]*PRIVATE KEY|untrusted comment: .*secret key)'; then
	die "pull request #$N adds what looks like a secret key — not merging"
fi

# --- 3. merge and test ---------------------------------------------------------
git checkout -q -b "$BR" "$BASE"
git merge -q --no-ff --no-commit "$HEAD_C" >/dev/null 2>&1 || die "pull request #$N does not merge cleanly — ask the author to rebase on main"
{
	printf 'Merge #%s: %s\n\n' "$N" "$TITLE"
	git log --reverse --format='%h %s' "$BASE..$HEAD_C"
	printf '\nPull request description (by @%s):\n\n' "$AUTHOR"
	json pr.json '(d.get("body") or "").replace("\r", "")' | sed 's/^/  /'
	python3 - "$W/comments.json" "$W/reviews.json" <<'PY'
import json, re, sys
acks = []
for f in sys.argv[1:]:
    for item in json.load(open(f)):
        for line in (item.get("body") or "").splitlines():
            if re.search(r"(?<![N\w])(tested |ut|cr|concept |re-)?ACK\b", line, re.I) and not re.search(r"\bNACK\b", line):
                acks.append("  %s:\n    %s" % (item["user"]["login"], line.strip()))
                break
if acks:
    print("\nACKs:\n" + "\n".join(dict.fromkeys(acks)))
PY
} >"$W/message"
git -c commit.gpgsign=false commit -q --no-verify -F "$W/message"
MERGE=$(git rev-parse HEAD)
if [ "$TEST" = 1 ]; then
	echo "merge-pr: running $TESTCMD …" >&2
	sh -c "$TESTCMD" >"$W/test.log" 2>&1 || { tail -30 "$W/test.log" >&2; die "the tests fail with pull request #$N merged — not merging"; }
fi

# --- 4. review and sign --------------------------------------------------------
echo
git log -1 --format=%B "$MERGE"
git diff --stat "$BASE" "$MERGE"
[ "$TEST" = 1 ] && echo "Tests: passed ($TESTCMD)" || echo "Tests: NOT run (--no-test)"
while :; do
	ask "Sign this merge with your PGP key? [s]ign / [d]iff / e[x]it:"
	case "$ans" in
		s) break ;;
		d) git diff "$BASE" "$MERGE" ;;
		*) die "stopped — nothing was pushed" ;;
	esac
done
git commit -q --amend --no-edit --no-verify -S || die "signing failed — nothing was pushed"
MERGE=$(git rev-parse HEAD)

# --- 5. verify and push --------------------------------------------------------
# The checker as it was on main before this merge, so a pull request cannot change how it is checked.
mkdir "$W/vc" && git archive "$BASE" contrib/verify-commits | tar -x -C "$W/vc"
"$W/vc/contrib/verify-commits/verify-commits.sh" "$MERGE" || die "the signed merge does not pass verify-commits — nothing was pushed"
ask "Push the signed merge to $REMOTE main? [y/N]"
[ "$ans" = y ] || die "not pushed — nothing changed on $REMOTE"
git push -q "$REMOTE" "$MERGE:refs/heads/main"
git checkout -q main && git merge -q --ff-only "$MERGE"
echo "merge-pr: pull request #$N merged and pushed ($(git rev-parse --short "$MERGE"))"
