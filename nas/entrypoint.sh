#!/bin/sh
set -eu

ip route replace 172.30.30.0/24 via 172.30.20.2

exec "$@"
