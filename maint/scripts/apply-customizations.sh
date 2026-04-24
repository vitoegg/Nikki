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
