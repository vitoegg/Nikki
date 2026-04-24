#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/opennikki-mihomo-verify.XXXXXX")

cleanup() {
	rm -rf "$WORKDIR"
}

trap cleanup EXIT INT TERM

MOCK_ROOT="$WORKDIR/mock"
MAKEFILE_DIR="$WORKDIR/repo/mihomo-meta"
OUTPUT_FILE="$WORKDIR/output.env"
mkdir -p "$MOCK_ROOT" "$MAKEFILE_DIR" "$WORKDIR/source/fake-repo"

printf '%s\n' \
	'{"tag_name":"v1.2.3","published_at":"2026-04-24T00:00:00Z"}' \
	> "$MOCK_ROOT/release.json"
printf '%s\n' \
	'{"commit":{"committer":{"date":"2026-04-24T00:00:00Z"}}}' \
	> "$MOCK_ROOT/commit.json"
printf 'mock source\n' > "$WORKDIR/source/fake-repo/README.md"
tar -C "$WORKDIR/source" -czf "$MOCK_ROOT/source.tar.gz" fake-repo
printf '%s\n' \
	'include $(TOPDIR)/rules.mk' \
	'' \
	'PKG_NAME:=mihomo-meta' \
	'PKG_VERSION:=1.2.2' \
	'PKG_SOURCE_VERSION:=v1.2.2' \
	'PKG_MIRROR_HASH:=oldhash' \
	'PKG_BUILD_VERSION:=v1.2.2' \
	> "$MAKEFILE_DIR/Makefile"

: > "$OUTPUT_FILE"
MAKEFILE_PATH="$MAKEFILE_DIR/Makefile" \
RELEASE_API_URL="file://${MOCK_ROOT}/release.json" \
TARBALL_URL_TEMPLATE="file://${MOCK_ROOT}/source.tar.gz" \
COMMIT_API_URL_TEMPLATE="file://${MOCK_ROOT}/commit.json" \
MAX_RETRIES=1 \
RETRY_DELAY=0 \
sh "$REPO_ROOT/maint/scripts/update-mihomo-core.sh" --output "$OUTPUT_FILE"

grep -Fq 'need_update=true' "$OUTPUT_FILE"
grep -Fq 'latest_version=v1.2.3' "$OUTPUT_FILE"
grep -Fq 'pkg_version=1.2.3' "$OUTPUT_FILE"
grep -Fq 'published_at=2026-04-24T00:00:00Z' "$OUTPUT_FILE"

updated_hash="$(awk -F= '$1 == "hash" { print substr($0, index($0, "=") + 1); exit }' "$OUTPUT_FILE")"
[ -n "$updated_hash" ] || {
	echo "Missing hash output" >&2
	exit 1
}

grep -Fq 'PKG_VERSION:=1.2.3' "$MAKEFILE_DIR/Makefile"
grep -Fq 'PKG_SOURCE_VERSION:=v1.2.3' "$MAKEFILE_DIR/Makefile"
grep -Fq 'PKG_BUILD_VERSION:=v1.2.3' "$MAKEFILE_DIR/Makefile"
grep -Fq "PKG_MIRROR_HASH:=${updated_hash}" "$MAKEFILE_DIR/Makefile"

: > "$OUTPUT_FILE"
MAKEFILE_PATH="$MAKEFILE_DIR/Makefile" \
RELEASE_API_URL="file://${MOCK_ROOT}/release.json" \
TARBALL_URL_TEMPLATE="file://${MOCK_ROOT}/source.tar.gz" \
COMMIT_API_URL_TEMPLATE="file://${MOCK_ROOT}/commit.json" \
MAX_RETRIES=1 \
RETRY_DELAY=0 \
sh "$REPO_ROOT/maint/scripts/update-mihomo-core.sh" --output "$OUTPUT_FILE"

grep -Fq 'need_update=false' "$OUTPUT_FILE"
grep -Fq 'skip=false' "$OUTPUT_FILE"

printf 'Mihomo updater verification succeeded\n'
