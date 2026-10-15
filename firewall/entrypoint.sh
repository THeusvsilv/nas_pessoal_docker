#!/bin/sh
set -eu

prefix=${NETWORK_PREFIX:-172.30}
external_if=$(ip -o -4 addr show | awk -v ip="$prefix.10.2/24" '$4 == ip {print $2}')
dmz_if=$(ip -o -4 addr show | awk -v ip="$prefix.20.2/24" '$4 == ip {print $2}')
home_if=$(ip -o -4 addr show | awk -v ip="$prefix.30.2/24" '$4 == ip {print $2}')

[ -n "$external_if" ] && [ -n "$dmz_if" ] && [ -n "$home_if" ]

iptables -F
iptables -t nat -F
iptables -X
iptables -t nat -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -A PREROUTING -i "$external_if" -p tcp --dport 80 \
  -j DNAT --to-destination "$prefix.20.10:80"

iptables -A FORWARD -i "$external_if" -o "$dmz_if" -p tcp \
  -d "$prefix.20.10" --dport 80 -m conntrack --ctstate NEW -j ACCEPT

# These are explicit policy blocks, rather than relying on a closed service.
iptables -A FORWARD -i "$dmz_if" -o "$home_if" -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "firewall-dmz-home-drop: " --log-level 4
iptables -A FORWARD -i "$dmz_if" -o "$home_if" -j DROP
iptables -A FORWARD -i "$external_if" -o "$home_if" -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "firewall-external-home-drop: " --log-level 4
iptables -A FORWARD -i "$external_if" -o "$home_if" -j DROP

# SNAT makes the NAS return traffic to this namespace, where conntrack reverses DNAT.
iptables -t nat -A POSTROUTING -o "$dmz_if" -s "$prefix.10.0/24" \
  -d "$prefix.20.10" -p tcp --dport 80 -j MASQUERADE

iptables -A FORWARD -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "firewall-drop: " --log-level 4

exec tail -f /dev/null
