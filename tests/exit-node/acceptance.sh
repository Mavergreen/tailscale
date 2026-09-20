#!/bin/sh
# Acceptance A1-A6, A8 against a PATCHED tailscaled (no manual routes). See the plan's Tasks 7-8.
# Run as root, detached:  sudo NETCHANGE=0 RESTARTS=launchd nohup sh acceptance.sh OUTDIR >/dev/null 2>&1 &
#   RESTARTS=launchd  tailscaled is a LaunchDaemon (KeepAlive restarts it after kill -9)
#   RESTARTS=none     tailscaled was started by hand; A4b leaves it dead (restart it yourself)
#   NETCHANGE=1       also run A5's network change (bounces the physical interface)
set -u
OUT=${1:?usage: acceptance.sh OUTDIR}
RESTARTS=${RESTARTS:-launchd}
mkdir -p "$OUT"
exec > "$OUT/acceptance.log" 2>&1
. "$(dirname "$0")/lib.sh"
TUN=$(tun_if) || { echo "ABORT: no Tailscale utun"; exit 1; }
PHYS=$(phys_if); GW4=$(gw4); GW6=$(gw6); BASE_ALLOW_LAN=$(base_allow_lan)
HOST=$(lan_host)
say "acceptance start $(date) tun=$TUN phys=$PHYS gw4=$GW4 host=$HOST restarts=$RESTARTS"
[ -n "$HOST" ] || { echo "ABORT: no LAN neighbor in the ARP table; ping one first"; exit 1; }
arm_watchdog 600
netstat -rn | grep -v W > "$OUT/routes.before"
run netstat -rn

say "baseline"
public_ips
run ping -c 2 -t 3 "$HOST"
dns_probe control

say "exit node on, LAN blocked"
m=$(log_mark)
run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=false
sleep 10
say "A2: tailscaled log since selecting (expect no router/route failures)"
log_since "$m"
say "A2: status (expect no router-related health warning)"
run ts status
say "routes on $TUN (expect 0/1, 128/1, ::/1, 8000::/1 and the LAN halves)"
netstat -rn | grep "$TUN"
say "A1: public IPs (expect the exit node's)"
public_ips
say "A2: loop check"
leak_check a2
say "A3a: LAN host from an ordinary process (expect 100% packet loss)"
run ping -c 2 -t 3 "$HOST"
say "A6: DNS (expect 0 packets on $PHYS)"
dns_probe exit

say "A3b: LAN allowed (expect LAN host replies, IPs still the exit node's)"
run ts set --exit-node-allow-lan-access=true
sleep 8
run ping -c 2 -t 3 "$HOST"
public_ips

say "A4a: exit node off (expect routing table identical to baseline)"
run ts set --exit-node= --exit-node-allow-lan-access="$BASE_ALLOW_LAN"
sleep 8
netstat -rn | grep -v W > "$OUT/routes.off"
run diff "$OUT/routes.before" "$OUT/routes.off"

say "A8: exit node off, tailnet behaves as before"
run ts ping -c 3 "$EXIT_NODE"
run ping -c 1 -t 3 "$(ts status | awk -v ip="$EXIT_NODE" '$1 == ip {print $2; exit}')"
netstat -rn | grep "$TUN"
public_ips

if [ "${NETCHANGE:-0}" = 1 ]; then
	say "A5: network change with exit node on"
	run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=false
	sleep 10
	run ifconfig "$PHYS" down
	sleep 10
	run ifconfig "$PHYS" up
	sleep 45
	TUN=$(tun_if)
	public_ips
	run ts status
	leak_check a5
	run ts set --exit-node= --exit-node-allow-lan-access="$BASE_ALLOW_LAN"
	sleep 8
fi

say "A4b: kill -9 with exit node on (expect internet via $PHYS, baseline IPs)"
run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=false
sleep 10
public_ips
run kill -9 "$(pgrep -x tailscaled | head -1)"
sleep 2
run route -n get 1.1.1.1
public_ips
if [ "$RESTARTS" = launchd ]; then
	say "A4b: after launchd restarts tailscaled (expect exit node's IPs again)"
	sleep 30
	TUN=$(tun_if)
	run ts status
	public_ips
fi

revert
disarm_watchdog
sleep 8
netstat -rn | grep -v W > "$OUT/routes.after"
say "final routes (expect no diff when tailscaled is running)"
run diff "$OUT/routes.before" "$OUT/routes.after"
say "acceptance DONE $(date)"
