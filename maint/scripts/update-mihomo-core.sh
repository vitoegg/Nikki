#!/bin/sh

set -eu

MAKEFILE_PATH="${MAKEFILE_PATH:-mihomo-meta/Makefile}"
UPSTREAM_REPO="${UPSTREAM_REPO:-MetaCubeX/mihomo}"
GH_TOKEN="${GH_TOKEN:-}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
OUTPUT_FILE="${GITHUB_OUTPUT:-}"
RELEASE_API_URL="${RELEASE_API_URL:-https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest}"
TARBALL_URL_TEMPLATE="${TARBALL_URL_TEMPLATE:-https://api.github.com/repos/${UPSTREAM_REPO}/tarball/%s}"
COMMIT_API_URL_TEMPLATE="${COMMIT_API_URL_TEMPLATE:-https://api.github.com/repos/${UPSTREAM_REPO}/commits/%s}"

usage() {
	echo "Usage: sh maint/scripts/update-mihomo-core.sh [--output <file>]" >&2
	exit 1
}

append_output() {
	[ -n "$OUTPUT_FILE" ] || return 0
	printf '%s=%s\n' "$1" "$2" >> "$OUTPUT_FILE"
}

curl_get() {
	url="$1"
	shift
	if [ -n "$GH_TOKEN" ]; then
		curl -fsSL --retry "$MAX_RETRIES" --retry-delay "$RETRY_DELAY" \
			-H "Authorization: Bearer ${GH_TOKEN}" \
			"$@" "$url"
		return
	fi

	curl -fsSL --retry "$MAX_RETRIES" --retry-delay "$RETRY_DELAY" "$@" "$url"
}

build_url() {
	template="$1"
	value="$2"
	case "$template" in
		*%s*)
			printf "$template" "$value"
			;;
		*)
			printf '%s' "$template"
			;;
	esac
}

to_unix_timestamp() {
	input="$1"
	if date -d "$input" +%s >/dev/null 2>&1; then
		date -d "$input" +%s
		return
	fi

	date -j -f "%Y-%m-%dT%H:%M:%SZ" "$input" +%s
}

sha256_file() {
	file_path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file_path" | awk '{print $1}'
		return
	fi

	shasum -a 256 "$file_path" | awk '{print $1}'
}

replace_makefile_var() {
	key="$1"
	value="$2"
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/opennikki-mihomo-makefile.XXXXXX")"

	grep -Eq "^[[:space:]]*${key}:=" "$MAKEFILE_PATH" || {
		echo "Makefile 中缺少字段: ${key}" >&2
		rm -f "$tmp_file"
		exit 1
	}

	sed -E "s#^([[:space:]]*${key}:=).*#\\1${value}#" "$MAKEFILE_PATH" > "$tmp_file"
	mv "$tmp_file" "$MAKEFILE_PATH"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--output)
			[ "$#" -ge 2 ] || usage
			OUTPUT_FILE="$2"
			shift 2
			;;
		*)
			usage
			;;
	esac
done

[ -f "$MAKEFILE_PATH" ] || {
	echo "Makefile 不存在: ${MAKEFILE_PATH}" >&2
	exit 1
}

pkg_name="$(awk -F':=' '/^[[:space:]]*PKG_NAME:=/{print $2; exit}' "${MAKEFILE_PATH}" | tr -d ' \t\r\n')"
current_version="$(awk -F':=' '/^[[:space:]]*PKG_SOURCE_VERSION:=/{print $2; exit}' "${MAKEFILE_PATH}" | tr -d ' \t\r\n')"

if [ -z "$pkg_name" ] || [ -z "$current_version" ]; then
	echo "无法从 ${MAKEFILE_PATH} 读取 PKG_NAME 或 PKG_SOURCE_VERSION" >&2
	exit 1
fi

[ "$pkg_name" = "mihomo-meta" ] || {
	echo "目标 Makefile 不是 mihomo-meta: ${pkg_name}" >&2
	exit 1
}

append_output "pkg_name" "$pkg_name"
append_output "current_version" "$current_version"
echo "当前版本: ${current_version}"
echo "获取上游 release: ${RELEASE_API_URL}"

release_info="$(curl_get "${RELEASE_API_URL}" 2>/dev/null || true)"
latest_version="$(printf '%s' "${release_info}" | jq -r '.tag_name // empty' 2>/dev/null || true)"
published_at="$(printf '%s' "${release_info}" | jq -r '.published_at // empty' 2>/dev/null || true)"

if [ -z "${latest_version}" ] || [ -z "${published_at}" ]; then
	append_output "skip" "true"
	append_output "need_update" "false"
	echo "无法获取上游版本信息，跳过本次更新"
	exit 0
fi

pkg_version="${latest_version#v}"
[ -n "${pkg_version}" ] && [ "${pkg_version}" != "${latest_version}" ] || {
	echo "上游 tag 格式不符合 mihomo-meta 预期: ${latest_version}" >&2
	exit 1
}

append_output "skip" "false"
append_output "latest_version" "${latest_version}"
append_output "pkg_version" "${pkg_version}"
append_output "published_at" "${published_at}"
echo "上游最新版本: ${latest_version}"
echo "发布日期: ${published_at}"

if [ "${current_version}" = "${latest_version}" ]; then
	append_output "need_update" "false"
	echo "版本相同，无需更新"
	exit 0
fi

echo "发现新版本，需要更新"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/opennikki-mihomo-update.XXXXXX")"
cleanup() {
	rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

source_tarball="${work_dir}/source.tar.gz"
untar_dir="${work_dir}/untar"
subdir="${pkg_name}-${pkg_version}"
tarball_url="$(build_url "${TARBALL_URL_TEMPLATE}" "${latest_version}")"
commit_url="$(build_url "${COMMIT_API_URL_TEMPLATE}" "${latest_version}")"

echo "下载源码: ${tarball_url}"
curl_get "${tarball_url}" -o "${source_tarball}"

mkdir -p "${untar_dir}"
if tar --help 2>&1 | grep -q -- '--no-same-permissions'; then
	tar -xzf "${source_tarball}" -C "${untar_dir}" --no-same-permissions
else
	tar -xzf "${source_tarball}" -C "${untar_dir}"
fi

extracted_path="$(find "${untar_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
[ -n "${extracted_path}" ] || {
	echo "未找到解压目录" >&2
	exit 1
}

mv "${extracted_path}" "${untar_dir}/${subdir}"

echo "获取 commit 时间戳: ${commit_url}"
commit_info="$(curl_get "${commit_url}")"
commit_ts="$(printf '%s' "${commit_info}" | jq -r '.commit.committer.date // empty' 2>/dev/null || true)"
[ -n "${commit_ts}" ] || {
	echo "无法获取 commit 时间戳" >&2
	exit 1
}

timestamp="$(to_unix_timestamp "${commit_ts}")"
repacked_tarball="${work_dir}/${subdir}.tar.gz"

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	GZIP=-n tar --numeric-owner --owner=0 --group=0 --sort=name --mode=a-s \
		--mtime="@${timestamp}" \
		-C "${untar_dir}" -czf "${repacked_tarball}" "${subdir}"
else
	echo "检测到非 GNU tar，使用兼容模式打包；本地 hash 仅用于校验脚本。" >&2
	COPYFILE_DISABLE=1 tar -C "${untar_dir}" -czf "${repacked_tarball}" "${subdir}"
fi

hash="$(sha256_file "${repacked_tarball}")"

replace_makefile_var "PKG_VERSION" "${pkg_version}"
replace_makefile_var "PKG_SOURCE_VERSION" "${latest_version}"
replace_makefile_var "PKG_BUILD_VERSION" "${latest_version}"
replace_makefile_var "PKG_MIRROR_HASH" "${hash}"

append_output "need_update" "true"
append_output "hash" "${hash}"
echo "Makefile 已更新:"
grep -E "^[[:space:]]*(PKG_VERSION|PKG_SOURCE_VERSION|PKG_BUILD_VERSION|PKG_MIRROR_HASH):=" "${MAKEFILE_PATH}"
