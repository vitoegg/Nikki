#!/usr/bin/env python3

import argparse
import ipaddress
import sys
import tempfile
import urllib.request
from pathlib import Path


SOURCE_URL = "https://raw.githubusercontent.com/vitoegg/Provider/master/RuleSet/Extra/MosDNS/geoip.txt"
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TARGETS = (
    (4, REPO_ROOT / "nikki/files/nftables/geoip_cn.nft", "china_ip", "ipv4_addr"),
    (6, REPO_ROOT / "nikki/files/nftables/geoip6_cn.nft", "china_ip6", "ipv6_addr"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate nftables GeoIP sets from the upstream mixed geoip.txt source."
    )
    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument("--source-file", help="Read CIDRs from a local file instead of downloading")
    source_group.add_argument("--url", default=SOURCE_URL, help="Upstream geoip.txt URL")
    parser.add_argument("--check", action="store_true", help="Verify files are up to date without writing")
    parser.add_argument("--timeout", type=int, default=30, help="Download timeout in seconds")
    return parser.parse_args()


def load_source(args: argparse.Namespace) -> str:
    if args.source_file:
        return Path(args.source_file).read_text(encoding="utf-8")

    request = urllib.request.Request(
        args.url,
        headers={"User-Agent": "OpenNikki-geoip-nft-updater/1.0"},
    )
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        return response.read().decode("utf-8")


def parse_networks(raw_text: str) -> dict[int, list[str]]:
    grouped = {4: [], 6: []}
    seen: dict[int, set[str]] = {4: set(), 6: set()}

    for lineno, raw_line in enumerate(raw_text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        try:
            network = ipaddress.ip_network(line, strict=False)
        except ValueError as exc:
            raise ValueError(f"Invalid CIDR on line {lineno}: {line}") from exc

        cidr = str(network)
        if cidr in seen[network.version]:
            continue

        seen[network.version].add(cidr)
        grouped[network.version].append(network)

    # nft interval sets reject overlapping CIDRs, so collapse the source first.
    return {
        version: [str(network) for network in ipaddress.collapse_addresses(networks)]
        for version, networks in grouped.items()
    }


def render_nft(set_name: str, addr_type: str, networks: list[str]) -> str:
    lines = [
        "#!/usr/sbin/nft -f",
        "",
        "table inet nikki {",
        f"\tset {set_name} {{",
        f"\t\ttype {addr_type}",
        "\t\tflags interval",
        "\t\telements = {",
    ]

    for network in networks:
        lines.append(f"\t\t\t{network},")

    lines.extend(
        [
            "\t\t}",
            "\t}",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def sync_file(path: Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    changed = current != content

    if check or not changed:
        return changed

    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(content)
        temp_path = Path(handle.name)

    temp_path.replace(path)
    return changed


def main() -> int:
    args = parse_args()

    try:
        raw_text = load_source(args)
        grouped_networks = parse_networks(raw_text)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"Failed to refresh GeoIP nft rules: {exc}", file=sys.stderr)
        return 1

    changed_paths: list[Path] = []
    for version, path, set_name, addr_type in TARGETS:
        content = render_nft(set_name, addr_type, grouped_networks[version])
        changed = sync_file(path, content, args.check)
        status = "outdated" if args.check and changed else "updated" if changed else "unchanged"
        rel_path = path.relative_to(REPO_ROOT)
        print(f"{status}: {rel_path} ({len(grouped_networks[version])} entries)")
        if changed:
            changed_paths.append(path)

    if args.check and changed_paths:
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
