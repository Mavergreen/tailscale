#!/bin/sh
# Spike S3: does tailscaled's scutil global resolver actually win on this OS? (spec: Phase 0)
# Run as root, detached:  sudo nohup sh spike-s3-dns.sh OUTDIR >/dev/null 2>&1 &
set -u
OUT=${1:?usage: spike-s3-dns.sh OUTDIR}
mkdir -p "$OUT"
exec > "$OUT/s3.log" 2>&1
. "$(dirname "$0")/lib.sh"
TUN=$(tun_if) || { echo "ABORT: no Tailscale utun"; exit 1; }
PHYS=$(phys_if); GW4=$(gw4); GW6=$(gw6); BASE_ALLOW_LAN=$(base_allow_lan)
say "S3 start $(date) tun=$TUN phys=$PHYS allow_lan=$BASE_ALLOW_LAN"
arm_watchdog 300
netstat -rn | grep -v W > "$OUT/routes.before"

say "positive control: no exit node (expect DNS packets on $PHYS > 0)"
scutil --dns > "$OUT/scutil.before"
dns_probe control

say "select exit node (LAN allowed) + split default routes"
run ts set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true
sleep 8
add_route inet 0.0.0.0/1
add_route inet 128.0.0.0/1
add_route inet6 ::/1
add_route inet6 8000::/1
sleep 3

say "resolver configuration with exit node (100.100.100.100 must be the effective default)"
scutil --dns > "$OUT/scutil.exit"
cat "$OUT/scutil.exit"
run scutil <<'SCUTIL'
show State:/Network/Service/FF457792-79C0-4A25-8392-D875BBEACCA6/DNS
show State:/Network/Global/DNS
SCUTIL
say "DNS with exit node (expect DNS packets on $PHYS = 0, names still resolve)"
dns_probe exit

revert
disarm_watchdog
sleep 3
netstat -rn | grep -v W > "$OUT/routes.after"
say "routes restored (expect no diff)"
run diff "$OUT/routes.before" "$OUT/routes.after"
say "S3 DONE $(date)"
