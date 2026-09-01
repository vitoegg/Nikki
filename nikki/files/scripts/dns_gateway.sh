#!/bin/sh

. "$IPKG_INSTROOT/etc/nikki/scripts/include.sh"
. "$IPKG_INSTROOT/lib/functions/network.sh"

# MosDNS cgroupv2 路径，防止 DNS 回环
MOSDNS_CGROUP="services/mosdns"
MOSDNS_CGROUP_LEVEL=2

apply() {
	local interface
	local device
	local elements
	elements=""
	# 复用 nikki 的 LAN 入站接口配置，与 hijack 保持同一作用域
	for interface in $(uci -q get nikki.proxy.lan_inbound_interface); do
		network_get_device device "$interface" || continue
		elements="${elements:+$elements, }\"$device\""
	done

	cleanup

	# 无可用入站接口时不下发规则，避免无来源约束的 DNS 劫持
	[ -n "$elements" ] || return 1

	nft -f - <<-EOF
	table inet dns_gateway {
		chain prerouting {
			type nat hook prerouting priority -110; policy accept;
			iifname != { $elements } counter return comment "Non-LAN bypass"
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
	return 0
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
