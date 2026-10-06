#!/usr/bin/env bash
# Usage: scripts/verify-release.sh DIR TAG REPO COMMIT
#
# Checks release assets downloaded into DIR (`gh release download TAG`):
# SHA256SUMS lists exactly the tarballs and they match it, and each
# tarball's provenance attestation was signed by REPO's release.yml for TAG
# (edge.yml on main, for "edge"), built from COMMIT, on a GitHub-hosted
# runner. Needs an authenticated gh. Stops at the first failure with
# "FAIL (checksums|attestation): ..." (scripts/verify-release_test.sh
# checks it catches tampering).
set -euo pipefail
dir=${1:?dir}; tag=${2:?tag}; repo=${3:?repo}; commit=${4:?commit}

fail() { echo "FAIL ($1): $2" >&2; exit 1; }
if [ "$tag" = edge ]; then
	signer=$repo/.github/workflows/edge.yml ref=refs/heads/main
else
	signer=$repo/.github/workflows/release.yml ref=refs/tags/$tag
fi

shopt -s nullglob
tarballs=("$dir"/hwspec-*.tar.gz)
[ ${#tarballs[@]} -gt 0 ] || fail checksums "no hwspec-*.tar.gz in $dir"
[ -f "$dir/SHA256SUMS" ] || fail checksums "no SHA256SUMS in $dir"
# sha256sum -c skips files SHA256SUMS doesn't name, so compare the lists.
listed=$(awk '{ sub(/^\*/, "", $2); print $2 }' "$dir/SHA256SUMS" | sort | paste -sd' ')
present=$(for f in "${tarballs[@]}"; do basename "$f"; done | sort | paste -sd' ')
[ "$listed" = "$present" ] || fail checksums "SHA256SUMS lists [$listed], the release has [$present]"
(cd "$dir" && sha256sum -c --quiet SHA256SUMS) || fail checksums "a tarball doesn't match SHA256SUMS"

for f in "${tarballs[@]}"; do
	gh attestation verify "$f" --repo "$repo" --signer-workflow "$signer@$ref" \
		--source-ref "$ref" --source-digest "$commit" --deny-self-hosted-runners >/dev/null ||
		fail attestation "$(basename "$f") isn't attested by $signer@$ref at $commit"
done
echo "ok: ${#tarballs[@]} tarballs match SHA256SUMS and are attested by $signer@$ref at $commit"
