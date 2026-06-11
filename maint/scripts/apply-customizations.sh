#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PATCH_DIR="$REPO_ROOT/maint/patches"
REMOVE_MANIFEST="$REPO_ROOT/maint/manifests/remove-paths.txt"
RESTORE_MANIFEST="$REPO_ROOT/maint/manifests/restore-paths.txt"
TMPDIR_ROOT="${TMPDIR:-/tmp}"

usage() {
	echo "Usage: sh maint/scripts/apply-customizations.sh [--check] <target-dir>" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || {
		echo "Missing file: $1" >&2
		exit 1
	}
}

validate_restore_paths() {
	while IFS= read -r path || [ -n "$path" ]; do
		case "$path" in
			''|\#*)
				continue
				;;
		esac

		[ -e "$REPO_ROOT/$path" ] || {
			echo "Missing restore path in repo: $path" >&2
			exit 1
		}
	done < "$RESTORE_MANIFEST"
}

remove_upstream_paths() {
	[ -f "$REMOVE_MANIFEST" ] || {
		echo "Missing remove manifest: $REMOVE_MANIFEST" >&2
		exit 1
	}

	while IFS= read -r path || [ -n "$path" ]; do
		case "$path" in
			''|\#*)
				continue
				;;
			esac
			rm -rf "$TARGET_DIR/$path"
		done < "$REMOVE_MANIFEST"
}

restore_custom_paths() {
	while IFS= read -r path || [ -n "$path" ]; do
		case "$path" in
			''|\#*)
				continue
				;;
		esac

		rm -rf "$TARGET_DIR/$path"
		tar -C "$REPO_ROOT" -cf - "$path" | tar -C "$TARGET_DIR" -xf -
	done < "$RESTORE_MANIFEST"
}

apply_patch_stack() {
	find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort | while IFS= read -r patch_path; do
		patch_name=$(basename "$patch_path")
		printf '[%s] %s\n' "$MODE_LABEL" "$patch_name"
		git -C "$TARGET_DIR" apply --whitespace=nowarn "$patch_path"
	done
}

line_of() {
	awk -v pattern="$2" 'index($0, pattern) { print NR; exit }' "$1"
}

require_single_occurrence() {
	file="$1"
	pattern="$2"
	label="$3"
	count=$(grep -F -c "$pattern" "$file" || true)
	[ "$count" = 1 ] || {
		echo "Invalid $label occurrence count: $count" >&2
		exit 1
	}
}

validate_quic_reject() {
	init_file="$TARGET_DIR/nikki/files/nikki.init"
	hijack_file="$TARGET_DIR/nikki/files/ucode/hijack.ut"
	quic_success='log "QUIC" "Reject successful."'
	quic_failed='log "QUIC" "Reject failed."'
	quic_rule='iifname @lan_inbound_device udp dport 443 counter reject with icmpx type port-unreachable comment "QUIC Reject"'

	[ -f "$init_file" ] || {
		echo "Missing target file: nikki/files/nikki.init" >&2
		exit 1
	}
	[ -f "$hijack_file" ] || {
		echo "Missing target file: nikki/files/ucode/hijack.ut" >&2
		exit 1
	}

	require_single_occurrence "$init_file" "$quic_success" "QUIC success log"
	require_single_occurrence "$init_file" "$quic_failed" "QUIC failed log"
	require_single_occurrence "$hijack_file" "$quic_rule" "QUIC reject rule"

	proxy_success_line=$(line_of "$init_file" 'log "Proxy" "Hijack successful."')
	quic_success_line=$(line_of "$init_file" "$quic_success")
	proxy_failed_line=$(line_of "$init_file" 'log "Proxy" "Hijack failed."')
	quic_failed_line=$(line_of "$init_file" "$quic_failed")
	app_exit_line=$(awk -v start="$proxy_failed_line" 'NR > start && index($0, "log \"App\" \"Exit.\"") { print NR; exit }' "$init_file")
	[ "$proxy_success_line" -lt "$quic_success_line" ] && [ "$quic_success_line" -lt "$proxy_failed_line" ] && \
		[ "$proxy_failed_line" -lt "$quic_failed_line" ] && [ "$quic_failed_line" -lt "$app_exit_line" ] || {
		echo "Invalid QUIC log placement in nikki/files/nikki.init" >&2
		exit 1
	}

	chain_line=$(line_of "$hijack_file" 'chain mangle_prerouting_lan {')
	quic_rule_line=$(line_of "$hijack_file" "$quic_rule")
	vmap_line=$(line_of "$hijack_file" 'iifname @lan_inbound_device meta l4proto vmap')
	[ "$chain_line" -lt "$quic_rule_line" ] && [ "$quic_rule_line" -lt "$vmap_line" ] || {
		echo "Invalid QUIC reject rule placement in nikki/files/ucode/hijack.ut" >&2
		exit 1
	}
}

MODE="apply"
CHECK_WORKDIR=""
TARGET_DIR=""
TEMP_GIT_REPO_CREATED=0
if [ "${1:-}" = "--check" ]; then
	MODE="check"
	shift
fi

[ "$#" -eq 1 ] || usage
require_file "$REMOVE_MANIFEST"
require_file "$RESTORE_MANIFEST"
validate_restore_paths

SOURCE_TARGET=$(CDPATH= cd -- "$1" && pwd)
[ -d "$SOURCE_TARGET" ] || {
	echo "Target directory does not exist: $SOURCE_TARGET" >&2
	exit 1
}

[ "$SOURCE_TARGET" != "$REPO_ROOT" ] || {
	echo "Target directory must differ from repo root: $SOURCE_TARGET" >&2
	exit 1
}

cleanup() {
	if [ "$TEMP_GIT_REPO_CREATED" = 1 ] && [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR/.git" ]; then
		rm -rf "$TARGET_DIR/.git"
	fi
	if [ -n "$CHECK_WORKDIR" ]; then
		rm -rf "$CHECK_WORKDIR"
	fi
}

trap cleanup EXIT INT TERM

TARGET_DIR="$SOURCE_TARGET"
MODE_LABEL="$MODE"
if [ "$MODE" = "check" ]; then
	CHECK_WORKDIR=$(mktemp -d "$TMPDIR_ROOT/opennikki-customize-check.XXXXXX")
	cp -R "$SOURCE_TARGET"/. "$CHECK_WORKDIR"
	TARGET_DIR="$CHECK_WORKDIR"
	MODE_LABEL="check"
fi

if ! git -C "$TARGET_DIR" rev-parse --show-toplevel > /dev/null 2>&1; then
	git -C "$TARGET_DIR" init -q
	TEMP_GIT_REPO_CREATED=1
fi

remove_upstream_paths
echo "[$MODE_LABEL] cleanup removed paths"

apply_patch_stack

restore_custom_paths
echo "[$MODE_LABEL] restore custom paths"

validate_quic_reject
echo "[$MODE_LABEL] validate QUIC reject"
