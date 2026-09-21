#!/usr/bin/env bash
# One-time root setup for the Spark inference stack. Idempotent.
#
#   sudo ~/ai-stack/bin/privileged-setup.sh <lan-cidr>
#
# <lan-cidr> is your local subnet in CIDR form. It is an argument (or LAN_CIDR)
# rather than a default because this repository is public: no private-network
# address is ever written into a tracked file.
#
# What this changes:
#   1. Enables linger for the user, so the llama-swap user service starts at
#      boot without someone logging in first.
#   2. Opens two TCP ports to the local subnet only (<lan-cidr>):
#        9292 - llama-swap, the OpenAI-compatible API (requires a bearer token)
#        3000 - Open WebUI
#      Nothing is opened to the internet; the default deny policy is untouched.
#   3. Opens 9292 to the local Docker bridge subnets, because Open WebUI and
#      the nemoclaw sandbox are containers and reach the API through the host
#      gateway, which arrives in the INPUT chain from a bridge address.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

USER_NAME="${STACK_USER:-${SUDO_USER:-}}"
[ -n "$USER_NAME" ] || { echo "cannot tell which account owns the stack: run via sudo, or set STACK_USER" >&2; exit 1; }
LAN="${1:-${LAN_CIDR:-}}"
[ -n "$LAN" ] || { echo "usage: sudo $0 <lan-cidr>   (or set LAN_CIDR)" >&2; exit 1; }
API_PORT=9292
UI_PORT=3000

echo "== linger =="
loginctl enable-linger "$USER_NAME"
loginctl show-user "$USER_NAME" -p Linger

echo
echo "== LAN access to API and web UI =="
ufw allow from "$LAN" to any port "$API_PORT" proto tcp comment 'llama-swap OpenAI API'
ufw allow from "$LAN" to any port "$UI_PORT" proto tcp comment 'Open WebUI'

echo
echo "== Docker bridge access to the API =="
docker network ls -q \
  | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
  | grep -E '^(172\.|10\.|192\.168\.)' \
  | sort -u \
  | while read -r subnet; do
      echo "   allowing $subnet -> $API_PORT"
      ufw allow from "$subnet" to any port "$API_PORT" proto tcp comment 'llama-swap (docker bridge)'
    done

echo
echo "== resulting firewall state =="
ufw status verbose
