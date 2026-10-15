#!/bin/sh
set -eu

# Capacidade de laboratório: força destinos de outras redes pelo firewall.
ip route replace 172.30.20.0/24 via 172.30.10.2
ip route replace 172.30.30.0/24 via 172.30.10.2

exec "$@"
