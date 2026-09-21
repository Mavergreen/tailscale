#!/bin/sh
# Spike S1: split default routes by hand (spec: Phase 0).
# Run as root, detached:  sudo NETCHANGE=0 nohup sh spike-s1-default-routes.sh OUTDIR >/dev/null 2>&1 &
# Logs to OUTDIR/s1.log and reverts itself; the watchdog reverts after 300s regardless.
set -u
OUT=${1:?usage: spike-s1-default-routes.sh OUTDIR}
mkdir -p "$OUT"
exec > "$OUT/s1.log" 2>&1
. "$(dirname "$0")/lib.sh"
TUN=$(tun_if) || { echo "ABORT: no Tailscale utun"; exit 1; }
PHYS=$(phys_if); GW4=$(gw4); GW6=$(gw6); BASE_ALLOW_LAN=$(base_allow_lan)
say "S1 start $(date) tun=$TUN phys=$PHYS gw4=$GW4 gw6=$GW6 allow_lan=$BASE_ALLOW_LAN"
record_default_baseline
arm_watchdog 300

netstat -rn | grep -v W > "$OUT/routes.before"
run netstat -rn
say "baseline"
public_ips
run ts netcheck

say "select exit node, LAN allowed (so only the default routes are requested)"
m=$(log_mark)
run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true
sleep 8
say "tailscaled's own route attempts (expect File exists for 0.0.0.0/0 and ::/0)"
log_since "$m"
say "exit node selected, no OS routes yet (expect baseline IPs)"
public_ips

say "add split default routes"
add_route inet 0.0.0.0/1
add_route inet 128.0.0.0/1
add_route inet6 ::/1
add_route inet6 8000::/1
sleep 3
run netstat -rn

say "S1 checks: exit node's IPs, healthy status/netcheck, 0 looping tailscaled packets"
public_ips
run ts status
run ts netcheck
leak_check s1
run lsof -nP -a -p "$(pgrep -x tailscaled | head -1)" -i

if [ "${NETCHANGE:-0}" = 1 ]; then
	say "network change: bounce $PHYS"
	run ifconfig "$PHYS" down
	sleep 10
	run ifconfig "$PHYS" up
	sleep 45
	public_ips
	run ts status
	leak_check s1-netchange
fi

revert
disarm_watchdog
sleep 3
netstat -rn | grep -v W > "$OUT/routes.after"
say "routes restored (expect no diff)"
run diff "$OUT/routes.before" "$OUT/routes.after"
public_ips
say "S1 DONE $(date)"
