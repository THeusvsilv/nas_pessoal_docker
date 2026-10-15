#!/bin/sh
set -eu

prefix=${NETWORK_PREFIX:-172.30}
ip route replace "$prefix.30.0/24" via "$prefix.20.2"

exec "$@"
