#!/bin/sh
# Print what the exit-node scripts will detect on this machine. Unprivileged and read-only.
set -u
. "$(dirname "$0")/lib.sh"
TUN=$(tun_if) || TUN="(none)"
PHYS=$(phys_if); GW4=$(gw4); GW6=$(gw6)
echo "tun=$TUN phys=$PHYS gw4=$GW4 gw6=$GW6"
echo "allow_lan=$(base_allow_lan)"
echo "lan4=$(lan4_halves)"
echo "lan6=$(lan6_halves)"
echo "lan_host=$(lan_host)"
echo "exit_node=$EXIT_NODE"
