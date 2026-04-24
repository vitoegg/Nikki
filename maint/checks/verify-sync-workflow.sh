#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/opennikki-workflow-verify.XXXXXX")
WORKFLOW_PATH=".github/workflows/sync-upstream.yml"
GEOIP_WORKFLOW_PATH=".github/workflows/update-geoip-nft.yml"
MIHOMO_WORKFLOW_PATH=".github/workflows/update-mihomo-core.yml"
REMOVE_MANIFEST="maint/manifests/remove-paths.txt"
RESTORE_MANIFEST="maint/manifests/restore-paths.txt"
MIHOMO_SCRIPT="maint/scripts/update-mihomo-core.sh"
WRITEBACK_SCRIPT="maint/scripts/workflow-writeback.sh"

cleanup() {
	rm -rf "$WORKDIR"
}

trap cleanup EXIT INT TERM

test -f "$WORKFLOW_PATH"
test -f "$GEOIP_WORKFLOW_PATH"
test -f "$MIHOMO_WORKFLOW_PATH"
test -f "$REMOVE_MANIFEST"
test -f "$RESTORE_MANIFEST"
test -f "$MIHOMO_SCRIPT"
test -f "$WRITEBACK_SCRIPT"
test ! -e "maint/nikki"

grep -Fq "name: Sync Upstream" "$WORKFLOW_PATH"
grep -Fq "workflow_dispatch:" "$WORKFLOW_PATH"
! grep -Fq "schedule:" "$WORKFLOW_PATH"
grep -Fq "contents: write" "$WORKFLOW_PATH"
grep -Fq "actions: write" "$WORKFLOW_PATH"
grep -Fq "UPSTREAM_REPO: nikkinikki-org/OpenWrt-nikki" "$WORKFLOW_PATH"
grep -Fq "MIHOMO_UPSTREAM_REPO: MetaCubeX/mihomo" "$WORKFLOW_PATH"
grep -Fq "TARGET_BRANCH: master" "$WORKFLOW_PATH"
grep -Fq "GEOIP_SOURCE_URL: https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/MosDNS/geoip.txt" "$WORKFLOW_PATH"
grep -Fq "GH_TOKEN: \${{ github.token }}" "$WORKFLOW_PATH"
grep -Fq '. maint/scripts/workflow-writeback.sh' "$WORKFLOW_PATH"
grep -Fq 'workflow_writeback_config_git' "$WORKFLOW_PATH"
grep -Fq 'sh maint/scripts/update-mihomo-core.sh --output "$mihomo_output"' "$WORKFLOW_PATH"
grep -Fq 'git add -A' "$WORKFLOW_PATH"
grep -Fq 'workflow_writeback_has_staged_changes' "$WORKFLOW_PATH"
grep -Fq 'git reset --quiet' "$WORKFLOW_PATH"
grep -Fq 'git push origin HEAD:${TARGET_BRANCH}' "$WORKFLOW_PATH"
grep -Fq 'git commit -m "sync: upstream ${short_upstream_sha}"' "$WORKFLOW_PATH"
grep -Fq 'git commit -m "chore(geoip): refresh nft rules"' "$WORKFLOW_PATH"
grep -Fq 'git commit -m "chore: update mihomo-meta to ${latest_mihomo_version}"' "$WORKFLOW_PATH"
grep -Fq -e '-m "Source: ${UPSTREAM_REPO}@${upstream_sha}"' "$WORKFLOW_PATH"
grep -Fq -e '-m "Source: ${GEOIP_SOURCE_URL}"' "$WORKFLOW_PATH"
grep -Fq -e '-m "Mode: apply OpenNikki customizations"' "$WORKFLOW_PATH"
grep -Fq -e '-m "Mode: refresh GeoIP nft rules"' "$WORKFLOW_PATH"
grep -Fq 'CUSTOMIZATION_STATUS=conflict' "$WORKFLOW_PATH"
grep -Fq 'echo "customization_status=${customization_status}" >> "${GITHUB_OUTPUT}"' "$WORKFLOW_PATH"
grep -Fq 'echo "- Mihomo update: \`${mihomo_status}\`"' "$WORKFLOW_PATH"
grep -Fq 'exit 1' "$WORKFLOW_PATH"
grep -Fq 'sh maint/scripts/apply-customizations.sh "$upstream_dir" >"$apply_log" 2>&1' "$WORKFLOW_PATH"
grep -Fq 'find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +' "$WORKFLOW_PATH"
grep -Fq 'cp -R "$upstream_dir"/. .' "$WORKFLOW_PATH"
grep -Fq 'python3 maint/scripts/update-geoip-nft.py --url "${GEOIP_SOURCE_URL}"' "$WORKFLOW_PATH"
grep -Fq 'Unexpected GeoIP output under maint/nikki' "$WORKFLOW_PATH"
grep -Fq "name: Delete Workflow Runs" "$WORKFLOW_PATH"
grep -Fq "if: always()" "$WORKFLOW_PATH"
grep -Fq "uses: ophub/delete-releases-workflows@main" "$WORKFLOW_PATH"
grep -Fq "gh_token: \${{ secrets.GITHUB_TOKEN }}" "$WORKFLOW_PATH"

grep -Fq "name: Update GeoIP NFT" "$GEOIP_WORKFLOW_PATH"
grep -Fq "actions: write" "$GEOIP_WORKFLOW_PATH"
grep -Fq '. maint/scripts/workflow-writeback.sh' "$GEOIP_WORKFLOW_PATH"
grep -Fq 'workflow_writeback_has_staged_changes' "$GEOIP_WORKFLOW_PATH"
grep -Fq 'python3 maint/scripts/update-geoip-nft.py --url "${GEOIP_SOURCE_URL}"' "$GEOIP_WORKFLOW_PATH"
grep -Fq 'Unexpected GeoIP output under maint/nikki' "$GEOIP_WORKFLOW_PATH"
grep -Fq 'git add nikki/files/nftables/geoip_cn.nft nikki/files/nftables/geoip6_cn.nft' "$GEOIP_WORKFLOW_PATH"
grep -Fq 'git push origin HEAD:${TARGET_BRANCH}' "$GEOIP_WORKFLOW_PATH"
grep -Fq "if: always()" "$GEOIP_WORKFLOW_PATH"

grep -Fq "name: Update Mihomo Core" "$MIHOMO_WORKFLOW_PATH"
grep -Fq "group: opennikki-master-writes" "$MIHOMO_WORKFLOW_PATH"
grep -Fq 'sh maint/scripts/update-mihomo-core.sh' "$MIHOMO_WORKFLOW_PATH"
grep -Fq '. maint/scripts/workflow-writeback.sh' "$MIHOMO_WORKFLOW_PATH"
grep -Fq 'workflow_writeback_set_output "commit_sha" "${commit_sha}"' "$MIHOMO_WORKFLOW_PATH"
grep -Fq 'git push origin HEAD:${TARGET_BRANCH}' "$MIHOMO_WORKFLOW_PATH"
grep -Fq "steps.writeback.outputs.commit_sha" "$MIHOMO_WORKFLOW_PATH"
grep -Fq 'echo "## Mihomo core update result"' "$MIHOMO_WORKFLOW_PATH"
grep -Fq "if: always()" "$MIHOMO_WORKFLOW_PATH"

grep -Fxq '.github' "$REMOVE_MANIFEST"
grep -Fxq 'README.md' "$REMOVE_MANIFEST"
grep -Fxq 'README.zh.md' "$REMOVE_MANIFEST"

grep -Fxq 'README.md' "$RESTORE_MANIFEST"
grep -Fxq '.github' "$RESTORE_MANIFEST"
grep -Fxq 'maint' "$RESTORE_MANIFEST"

sh -n "$WRITEBACK_SCRIPT"
sh -n "$MIHOMO_SCRIPT"

(
	cd "$WORKDIR"
	git init -q
	git config user.name "verify"
	git config user.email "verify@example.com"
	printf 'tracked\n' > tracked.txt
	git add tracked.txt
	git commit -qm init
	printf 'added\n' > added.txt
	. "$REPO_ROOT/$WRITEBACK_SCRIPT"
	git add -A
	workflow_writeback_has_staged_changes
)

printf 'Workflow verification succeeded for %s\n' "$WORKFLOW_PATH"
