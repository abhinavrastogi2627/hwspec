#!/usr/bin/env bash
# Usage: scripts/verify-release_test.sh TAG REPO
#
# Proves scripts/verify-release.sh catches tampering, on a local copy of a
# real release: nothing published changes. Downloads TAG's assets once,
# then checks each case on a fresh copy: the untouched assets pass, and
# every tampered variant fails at the expected check.
set -euo pipefail
tag=${1:?tag}; repo=${2:?repo}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

commit=$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha)
gh release download "$tag" --repo "$repo" --dir "$work/orig" --pattern 'hwspec-*.tar.gz' --pattern SHA256SUMS
amd64=$(cd "$work/orig" && ls hwspec-*-linux-amd64.tar.gz)

# Tampering, run inside a case's copy of the assets.
# shellcheck disable=SC2329 # both are called through case_'s "$@"
append_byte() { printf x >>"$amd64"; }
# shellcheck disable=SC2329
append_byte_and_rehash() { append_byte && sha256sum hwspec-*.tar.gz >SHA256SUMS; }

# case_ NAME EXPECT(pass|checksums|attestation) TAG COMMIT [TAMPER-COMMAND...]
fail=0
case_() {
	local name=$1 want=$2 t=$3 c=$4 d="$work/$1" got
	shift 4
	cp -r "$work/orig" "$d"
	if [ $# -gt 0 ]; then (cd "$d" && "$@"); fi
	if out=$("$here/verify-release.sh" "$d" "$t" "$repo" "$c" 2>&1); then
		got=pass
	else
		got=$(sed -n 's/^FAIL (\([a-z]*\)).*/\1/p' <<<"$out" | tail -n 1)
	fi
	if [ "$got" = "$want" ]; then
		echo "ok   $name: $want"
	else
		echo "FAIL $name: got '${got:-error}', want '$want'"
		echo "     ${out//$'\n'/$'\n'     }"
		fail=1
	fi
}

case_ untouched pass "$tag" "$commit"
case_ tarball-changed checksums "$tag" "$commit" append_byte
# The attacker also rewrites SHA256SUMS: only the attestation catches it.
case_ tarball-and-sums-changed attestation "$tag" "$commit" append_byte_and_rehash
case_ tarball-added checksums "$tag" "$commit" cp "$amd64" hwspec-extra-linux-amd64.tar.gz
case_ tarball-unlisted checksums "$tag" "$commit" sed -i "/$amd64/d" SHA256SUMS
case_ other-commit attestation "$tag" 0000000000000000000000000000000000000000
other=edge; [ "$tag" = edge ] && other=v0.0.0
case_ other-signer attestation "$other" "$commit" # edge.yml's build presented as a release, or the reverse

[ "$fail" = 0 ] && echo "verify-release: tampering caught in every case"
exit "$fail"
