#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TMPDIR_ROOT="${TMPDIR:-/tmp}"
WORKDIR=$(mktemp -d "$TMPDIR_ROOT/opennikki-customize-verify.XXXXXX")

cleanup() {
	rm -rf "$WORKDIR"
}

trap cleanup EXIT INT TERM

SYNC_COMMIT="$(git -C "$REPO_ROOT" log --grep='^sync: upstream ' -n 1 --format='%H' || true)"
[ -n "$SYNC_COMMIT" ] || {
	echo "Missing sync baseline: no 'sync: upstream' commit found in $REPO_ROOT" >&2
	exit 1
}

SOURCE_REF="$(git -C "$REPO_ROOT" log -1 --format=%B "$SYNC_COMMIT" | awk '
	/^Source: / {
		sub(/^Source: /, "", $0)
		print
		exit
	}
')"
[ -n "$SOURCE_REF" ] || {
	echo "Missing Source trailer in sync commit: $SYNC_COMMIT" >&2
	exit 1
}

UPSTREAM_REPO="${SOURCE_REF%@*}"
UPSTREAM_SHA="${SOURCE_REF##*@}"
[ "$UPSTREAM_REPO" != "$SOURCE_REF" ] && [ -n "$UPSTREAM_SHA" ] || {
	echo "Invalid Source trailer in sync commit: $SOURCE_REF" >&2
	exit 1
}

UPSTREAM_ARCHIVE="$WORKDIR/upstream.tar.gz"
UPSTREAM_EXTRACT="$WORKDIR/upstream-extract"
UPSTREAM_URL="https://codeload.github.com/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_SHA}"

mkdir -p "$UPSTREAM_EXTRACT"
curl -fsSL --retry 3 --retry-delay 2 "$UPSTREAM_URL" -o "$UPSTREAM_ARCHIVE"
tar -xzf "$UPSTREAM_ARCHIVE" -C "$UPSTREAM_EXTRACT"

UPSTREAM_DIR="$(find "$UPSTREAM_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
[ -n "$UPSTREAM_DIR" ] || {
	echo "Failed to extract upstream archive from $UPSTREAM_URL" >&2
	exit 1
}

sh "$REPO_ROOT/maint/scripts/apply-customizations.sh" "$UPSTREAM_DIR"

test -f "$UPSTREAM_DIR/nikki/files/scripts/dns_gateway.sh"
test -f "$UPSTREAM_DIR/README.md"
test -d "$UPSTREAM_DIR/.github"
test -f "$UPSTREAM_DIR/.github/workflows/sync-upstream.yml"
test -f "$UPSTREAM_DIR/.github/workflows/update-mihomo-core.yml"
test -f "$UPSTREAM_DIR/.github/workflows/update-geoip-nft.yml"
test -f "$UPSTREAM_DIR/maint/scripts/update-mihomo-core.sh"
test -f "$UPSTREAM_DIR/maint/scripts/workflow-writeback.sh"
test -f "$UPSTREAM_DIR/maint/patches/0001-dns-gateway.patch"
test -f "$UPSTREAM_DIR/maint/patches/0002-quic-reject.patch"
test ! -e "$UPSTREAM_DIR/maint/patches/series"
test ! -e "$UPSTREAM_DIR/.git"
test ! -e "$UPSTREAM_DIR/feed.sh"
test ! -e "$UPSTREAM_DIR/install.sh"
test ! -e "$UPSTREAM_DIR/uninstall.sh"
test ! -e "$UPSTREAM_DIR/README.zh.md"
test ! -e "$UPSTREAM_DIR/.github/FUNDING.yml"
test ! -e "$UPSTREAM_DIR/.github/ISSUE_TEMPLATE"
test ! -e "$UPSTREAM_DIR/.github/workflows/build-packages.yml"

grep -Fq '# OpenNikki' "$UPSTREAM_DIR/README.md"
grep -Fq '**Custom patches**: `maint/patches/`' "$UPSTREAM_DIR/README.md"
grep -Fq '**Maintenance scripts**: `maint/scripts/`' "$UPSTREAM_DIR/README.md"
grep -Fq 'GeoIP nft 规则定期自动更新' "$UPSTREAM_DIR/README.md"
grep -Fq 'DNS_GATEWAY_SH="$SH_DIR/dns_gateway.sh"' "$UPSTREAM_DIR/nikki/files/scripts/include.sh"
grep -Fq '$DNS_GATEWAY_SH apply' "$UPSTREAM_DIR/nikki/files/nikki.init"
grep -Fq '$DNS_GATEWAY_SH cleanup' "$UPSTREAM_DIR/nikki/files/nikki.init"
grep -Fq '$(INSTALL_BIN) $(CURDIR)/files/scripts/dns_gateway.sh $(1)/etc/nikki/scripts/dns_gateway.sh' "$UPSTREAM_DIR/nikki/Makefile"
grep -Fq 'log "QUIC" "Reject successful."' "$UPSTREAM_DIR/nikki/files/nikki.init"
grep -Fq 'log "QUIC" "Reject failed."' "$UPSTREAM_DIR/nikki/files/nikki.init"
grep -Fq 'iifname @lan_inbound_device udp dport 443 counter reject with icmpx type port-unreachable comment "QUIC Reject"' "$UPSTREAM_DIR/nikki/files/ucode/hijack.ut"
! grep -Fq 'udp dport 443 ip daddr != @china_ip counter reject comment "QUIC Reject"' "$UPSTREAM_DIR/nikki/files/ucode/hijack.ut"
! grep -Fq 'udp dport 443 ip6 daddr != @china_ip6 counter reject comment "QUIC Reject"' "$UPSTREAM_DIR/nikki/files/ucode/hijack.ut"
sh -n "$UPSTREAM_DIR/maint/scripts/update-mihomo-core.sh"
sh -n "$UPSTREAM_DIR/maint/scripts/workflow-writeback.sh"

UPDATER_CHECK_DIR="$WORKDIR/updater-check"
UPDATER_SOURCE_FILE="$WORKDIR/geoip-sample.txt"
mkdir -p "$UPDATER_CHECK_DIR"
tar -C "$REPO_ROOT" -cf - maint/scripts/update-geoip-nft.py nikki/files/nftables | tar -C "$UPDATER_CHECK_DIR" -xf -
cat > "$UPDATER_SOURCE_FILE" <<'EOF'
1.1.1.0/24
1.1.1.0/24
2001:db8::/32
EOF
python3 "$UPDATER_CHECK_DIR/maint/scripts/update-geoip-nft.py" --source-file "$UPDATER_SOURCE_FILE"
test -f "$UPDATER_CHECK_DIR/nikki/files/nftables/geoip_cn.nft"
test -f "$UPDATER_CHECK_DIR/nikki/files/nftables/geoip6_cn.nft"
test ! -e "$UPDATER_CHECK_DIR/maint/nikki"
grep -Fq '1.1.1.0/24,' "$UPDATER_CHECK_DIR/nikki/files/nftables/geoip_cn.nft"
grep -Fq '2001:db8::/32,' "$UPDATER_CHECK_DIR/nikki/files/nftables/geoip6_cn.nft"
printf 'Customization verification succeeded against upstream %s@%s\n' "$UPSTREAM_REPO" "$UPSTREAM_SHA"
