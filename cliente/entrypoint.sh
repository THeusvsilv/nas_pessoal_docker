#!/bin/sh
set -eu

# Capacidade de laboratório: força destinos de outras redes pelo firewall.
prefix=${NETWORK_PREFIX:-172.30}
ip route replace "$prefix.20.0/24" via "$prefix.10.2"
ip route replace "$prefix.30.0/24" via "$prefix.10.2"

exec "$@"
