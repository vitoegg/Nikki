#!/bin/sh

. "$IPKG_INSTROOT/etc/nikki/scripts/include.sh"

# MosDNS cgroupv2 路径，防止 DNS 回环
MOSDNS_CGROUP="services/mosdns"
MOSDNS_CGROUP_LEVEL=2

apply() {
	cleanup

	nft -f - <<-EOF
	table inet dns_gateway {
		chain prerouting {
			type nat hook prerouting priority -110; policy accept;
			meta nfproto ipv4 udp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv4 tcp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv6 udp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv6 tcp dport 53 counter redirect to :5533 comment "DNS Gateway"
		}
		chain output {
			type nat hook output priority -110; policy accept;
			socket cgroupv2 level $MOSDNS_CGROUP_LEVEL "$MOSDNS_CGROUP" counter return comment "MosDNS bypass"
			meta nfproto ipv4 udp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv4 tcp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv6 udp dport 53 counter redirect to :5533 comment "DNS Gateway"
			meta nfproto ipv6 tcp dport 53 counter redirect to :5533 comment "DNS Gateway"
		}
	}
	EOF
}

cleanup() {
	nft delete table inet dns_gateway > /dev/null 2>&1
}

case "${1:-}" in
	apply)
		apply
		;;
	cleanup)
		cleanup
		;;
	*)
		echo "Usage: $0 {apply|cleanup}" >&2
		exit 1
		;;
esac

exit 0
