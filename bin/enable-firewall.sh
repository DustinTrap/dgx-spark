#!/usr/bin/env bash
# Enable ufw safely: make sure SSH survives first, then turn it on.
#
#   sudo ~/ai-stack/bin/enable-firewall.sh
#
# ufw's default policy is deny-incoming. Enabling it without an allow rule for
# SSH would cut off remote logins, so this script adds that rule, proves it is
# present, and only then enables the firewall. Already-established connections
# survive via conntrack, but a new ssh session would not - hence the check.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

LAN=10.0.1.0/24
SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-22}"

echo "== sshd is listening on port $SSH_PORT =="
ss -ltn "sport = :$SSH_PORT" | tail -n +2 || true

echo
echo "== allowing SSH from $LAN BEFORE enabling =="
ufw allow from "$LAN" to any port "$SSH_PORT" proto tcp comment 'ssh from LAN'

echo
echo "== verifying the SSH rule is actually staged =="
if ! ufw show added | grep -q "port $SSH_PORT"; then
  echo "ABORT: no SSH allow rule found. Not enabling ufw." >&2
  exit 1
fi
ufw show added

echo
echo "== enabling =="
ufw --force enable

echo
echo "== final state =="
ufw status verbose

cat <<'NOTE'

Firewall is on. Before closing this terminal, open a SECOND terminal and
confirm you can still ssh in. If you cannot, run from this session:

    sudo ufw disable

NOTE
