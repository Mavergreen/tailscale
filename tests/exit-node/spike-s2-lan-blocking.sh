#!/bin/sh
# Spike S2: enforce LAN blocking by hand, then add link-local halves (spec: Phase 0).
# Run as root, detached:  sudo nohup sh spike-s2-lan-blocking.sh OUTDIR >/dev/null 2>&1 &
# Blocks the LAN for ~2 minutes: an SSH session from the LAN to this box will drop.
set -u
OUT=${1:?usage: spike-s2-lan-blocking.sh OUTDIR}
mkdir -p "$OUT"
exec > "$OUT/s2.log" 2>&1
. "$(dirname "$0")/lib.sh"
TUN=$(tun_if) || { echo "ABORT: no Tailscale utun"; exit 1; }
PHYS=$(phys_if); GW4=$(gw4); GW6=$(gw6); BASE_ALLOW_LAN=$(base_allow_lan)
LAN4=$(lan4_halves) || exit 1
LAN6=$(lan6_halves) || exit 1
HOST=$(lan_host)
say "S2 start $(date) tun=$TUN phys=$PHYS gw4=$GW4 gw6=$GW6 lan4=[$LAN4] lan6=[$LAN6] host=$HOST"
[ -n "$HOST" ] || { echo "ABORT: no LAN neighbor in the ARP table; ping one first"; exit 1; }
arm_watchdog 300
netstat -rn | grep -v W > "$OUT/routes.before"

say "baseline (expect LAN host and gateway reachable; note netcheck's PortMapping line)"
run ping -c 2 -t 3 "$HOST"
run ping -c 2 -t 3 "$GW4"
run ts netcheck

say "select exit node, LAN blocked"
m=$(log_mark)
run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=false
sleep 8
say "tailscaled's own route attempts (expect File exists for the defaults and LAN prefixes)"
log_since "$m"

say "step 1: split default routes + split LAN prefixes"
add_route inet 0.0.0.0/1
add_route inet 128.0.0.0/1
add_route inet6 ::/1
add_route inet6 8000::/1
for p in $LAN4; do add_route inet "$p"; done
for p in $LAN6; do add_route inet6 "$p"; done
sleep 3
run netstat -rn
run route -n get "$HOST"
run arp -an

say "step 1: ordinary process to LAN host and gateway (expect 100% packet loss)"
run ping -c 2 -t 3 "$HOST"
run ping -c 2 -t 3 "$GW4"
say "step 1: internet (expect the exit node's IPs)"
public_ips
say "step 1: tailscaled (expect healthy; PortMapping as in baseline = its bound sockets reach the gateway)"
run ts status
run ts netcheck
leak_check s2-step1

say "step 2: also split link-local fe80::/64 (ipnlocal requests it too)"
add_route inet6 fe80::/65
add_route inet6 fe80::8000:0:0:0/65
sleep 3
run netstat -rn -f inet6
say "step 2 checks (expect IPv6 still working for tailscaled; record whether route add accepted fe80)"
public_ips
run ts netcheck
run ping6 -c 2 "$GW6"
leak_check s2-step2

revert
disarm_watchdog
sleep 3
netstat -rn | grep -v W > "$OUT/routes.after"
say "routes restored (expect no diff)"
run diff "$OUT/routes.before" "$OUT/routes.after"
run ping -c 2 -t 3 "$HOST"
say "S2 DONE $(date)"
