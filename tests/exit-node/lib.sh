# Shared helpers for the tailscaled exit-node spikes and acceptance runs
# (docs/superpowers/specs/2026-09-14-tailscaled-darwin-exit-nodes-design.md).
# Sourced by the scripts beside it, never run directly. route(8), tcpdump and lsof on a root
# process need root, so the scripts run under sudo, detached, logging to a file.
#
# Detect interfaces and gateways BEFORE adding routes: once 0.0.0.0/1 is on the tunnel,
# `route get default` resolves through it.
#
# Env (all optional):
#   TS_BIN     tailscale CLI           (default /usr/local/bin/tailscale)
#   TS_SOCKET  tailscaled socket, when not the default
#   TSD_LOG    tailscaled log          (default /Library/Logs/Tailscale/tailscaled.log)
#   EXIT_NODE  exit node IP            (default 100.66.57.125, ap-juicer)

TS_BIN=${TS_BIN:-/usr/local/bin/tailscale}
TS_SOCKET=${TS_SOCKET:-}
TSD_LOG=${TSD_LOG:-/Library/Logs/Tailscale/tailscaled.log}
EXIT_NODE=${EXIT_NODE:-100.66.57.125}

ts() {
	if [ -n "$TS_SOCKET" ]; then "$TS_BIN" --socket="$TS_SOCKET" "$@"; else "$TS_BIN" "$@"; fi
}
say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

# The utun carrying this node's Tailscale IPv4 address.
tun_if() {
	for i in $(ifconfig -l); do
		case $i in
		utun*) ifconfig "$i" | grep -q 'inet 100\.' && { echo "$i"; return 0; } ;;
		esac
	done
	return 1
}
phys_if() { route -n get default | awk '/interface:/ {print $2}'; }
gw4() { route -n get default | awk '/gateway:/ {print $2}'; }
gw6() { route -n get -inet6 default 2>/dev/null | awk '/gateway:/ {print $2}'; }
base_allow_lan() {
	ts debug prefs | awk -F': ' '/"ExitNodeAllowLANAccess"/ {gsub(/[ ,]/, "", $2); print $2}'
}

# The physical interface's IPv4 /24, as its two /25 halves. Written against this box's LAN,
# not as a general prefix calculator (that is the Go change), so anything but /24 aborts.
lan4_halves() {
	set -- $(ifconfig "$PHYS" | awk '/inet / {print $2, $4; exit}')
	[ "${2:-}" = 0xffffff00 ] || { echo "ABORT: $PHYS netmask '${2:-}' is not /24" >&2; return 1; }
	n=${1%.*}
	echo "$n.0/25 $n.128/25"
}
# The physical interface's global IPv6 /64 (from its stable autoconf address), as two /65s.
lan6_halves() {
	a=$(ifconfig "$PHYS" | awk '/inet6 / && $2 !~ /^fe80/ && /prefixlen 64/ && !/temporary/ && !/deprecated/ {print $2; exit}')
	p=$(echo "$a" | cut -d: -f1-4)
	case $p in
	"" | *::* | *:) echo "ABORT: cannot derive a /64 from '$a'" >&2; return 1 ;;
	esac
	echo "$p::/65 $p:8000::/65"
}
# A live LAN neighbor that is not the gateway (needs GW4 and PHYS).
lan_host() {
	arp -an | grep " on $PHYS " | awk -v gw="$GW4" '
		/incomplete|ff:ff:ff:ff:ff:ff|permanent/ {next}
		{ ip = $2; gsub(/[()]/, "", ip); if (ip != gw) { print ip; exit } }'
}

log_mark() { wc -l < "$TSD_LOG" | tr -d ' '; }
log_since() {
	tail -n +"$(($1 + 1))" "$TSD_LOG" |
		grep -E 'router:|route (add|del)|[Hh]ealth|configuring router|Rebind|defIf|add failed|del failed|File exists|no route|UDP is blocked|open-conn-track'
}

# Whether the unscoped (no I flag) "default" route for $PHYS exists in FAMILY's table
# (FAMILY is inet or inet6, as netstat -rn -f FAMILY names it).
unscoped_default() {
	netstat -rn -f "$1" | awk -v phys="$PHYS" '
		$1 == "default" {
			flags = $3
			for (i = 4; i <= NF; i++) if ($i == phys) has_phys = 1
			if (has_phys && flags !~ /I/) found = 1
			has_phys = 0
		}
		END { exit !found }'
}

# Record, BEFORE any route is touched, whether the unscoped default existed per family, into
# $OUT so the watchdog subshell (a separate process) can read it back.
record_default_baseline() {
	unscoped_default inet && echo yes > "$OUT/default4.baseline" || echo no > "$OUT/default4.baseline"
	unscoped_default inet6 && echo yes > "$OUT/default6.baseline" || echo no > "$OUT/default6.baseline"
	say "default-route baseline: inet=$(cat "$OUT/default4.baseline") inet6=$(cat "$OUT/default6.baseline")"
}
# For each family whose unscoped default existed at baseline but is missing now, re-add it.
# Never adds one that wasn't there at baseline; never touches scoped (I-flagged) routes.
restore_default_routes() {
	if [ "$(cat "$OUT/default4.baseline" 2>/dev/null)" = yes ] && ! unscoped_default inet; then
		say "unscoped IPv4 default via $PHYS is missing; re-adding"
		run route -n add -inet default "$GW4"
	fi
	if [ "$(cat "$OUT/default6.baseline" 2>/dev/null)" = yes ] && ! unscoped_default inet6; then
		say "unscoped IPv6 default via $PHYS is missing; re-adding"
		run route -n add -inet6 default "$GW6"
	fi
}

# An interface-scoped default route for $PHYS (S1b: gives en0-bound sockets a scoped route to
# hit, the way a non-primary interface with its own DHCP lease already has). FAMILY is inet or
# inet6; GW is that family's gateway. Recorded in its own ledger (separate from routes-added)
# so revert never deletes a scoped default this run did not add.
add_scoped_default() {
	fam=$1
	case $fam in
	inet) gw=$GW4 ;;
	inet6) gw=$GW6 ;;
	esac
	printf '$ route -n add -%s -ifscope %s default %s\n' "$fam" "$PHYS" "$gw"
	if route -n add "-$fam" -ifscope "$PHYS" default "$gw" 2>&1; then
		echo "$fam" >> "$OUT/scoped-added"
		echo '[added]'
	else
		echo '[add failed]'
	fi
}

# Routes added by hand are recorded in a ledger so revert (or the watchdog) can remove exactly them.
add_route() {
	printf '$ route -q -n add -%s %s -iface %s\n' "$1" "$2" "$TUN"
	if route -q -n add "-$1" "$2" -iface "$TUN" 2>&1; then
		echo "$1 $2" >> "$OUT/routes-added"
		echo '[added]'
	else
		echo '[add failed]'
	fi
}
revert() {
	say "revert"
	if [ -f "$OUT/routes-added" ]; then
		while read -r fam pfx; do
			run route -q -n delete "-$fam" "$pfx" -iface "$TUN"
		done < "$OUT/routes-added"
		rm -f "$OUT/routes-added"
	fi
	run ts set --exit-node= --exit-node-allow-lan-access="$BASE_ALLOW_LAN"
	if [ -f "$OUT/scoped-added" ]; then
		while read -r fam; do
			run route -n delete "-$fam" -ifscope "$PHYS" default
		done < "$OUT/scoped-added"
		rm -f "$OUT/scoped-added"
	fi
	sleep 3
	restore_default_routes
}
arm_watchdog() { ( sleep "$1"; say "WATCHDOG FIRED after $1s"; revert ) & WATCHDOG=$!; }
disarm_watchdog() { kill "$WATCHDOG" 2>/dev/null; }

public_ips() {
	printf 'IPv4: %s\n' "$(curl -4 -s -m 10 http://api.ipify.org || echo FAILED)"
	printf 'IPv6: %s\n' "$(curl -6 -s -m 10 http://api6.ipify.org || echo FAILED)"
}

# Local ports of tailscaled's sockets (WireGuard, STUN, DERP, control).
tsd_ports() {
	lsof -nP -a -p "$(pgrep -x tailscaled | head -1)" -i 2>/dev/null |
		awk 'NR > 1 { split($9, a, "->"); n = split(a[1], b, /[:.\]]/); print b[n] }' | sort -u
}
# A loop shows up as tailscaled's own traffic inside the tunnel. A packet with a Tailscale
# address at BOTH ends is tailnet-to-tailnet, not a loop; drop only those. Anything else --
# including internet-bound traffic routed into the tunnel (src 100.x, dst public) -- is kept, so
# it is either a loop (when it is on one of tailscaled's ports) or a connection that predates the
# routes (harmless, reported).
leak_check() {
	tcpdump -n -l -i "$TUN" \
		'not ((src net 100.64.0.0/10 and dst net 100.64.0.0/10) or (src net fd7a:115c:a1e0::/48 and dst net fd7a:115c:a1e0::/48))' \
		> "$OUT/leak.$1" 2>/dev/null &
	tp=$!
	curl -4 -s -m 10 -o /dev/null http://example.com
	curl -6 -s -m 10 -o /dev/null http://example.com
	ts netcheck > /dev/null 2>&1
	ts ping -c 3 "$EXIT_NODE" > /dev/null 2>&1
	sleep 5
	kill "$tp"; wait "$tp" 2>/dev/null
	echo "non-tunnel packets on $TUN [$1]: $(wc -l < "$OUT/leak.$1" | tr -d ' ')"
	hits=0
	for p in $(tsd_ports); do
		c=$(grep -cE "\.$p[ :]" "$OUT/leak.$1")
		if [ "$c" -gt 0 ]; then echo "  tailscaled port $p: $c packets"; hits=$((hits + c)); fi
	done
	echo "tailscaled packets looping through $TUN [$1]: $hits (must be 0)"
	curl80=$(grep -cE '\.80[ :]' "$OUT/leak.$1")
	echo "curl packets seen on $TUN [$1]: $curl80 (must be > 0 while routes point at the tunnel)"
}

# DNS packets leaving the physical interface while resolving uncached names.
dns_probe() {
	dscacheutil -flushcache
	tcpdump -n -l -i "$PHYS" 'port 53' > "$OUT/dns.$1" 2>/dev/null &
	tp=$!
	sleep 2
	for name in example.com wikipedia.org tailscale.com "t$(date +%s).example.net"; do
		printf '%s -> %s\n' "$name" "$(dscacheutil -q host -a name "$name" | awk '/ip_address/ {print $2; exit}')"
	done
	sleep 3
	kill "$tp"; wait "$tp" 2>/dev/null
	echo "DNS packets on $PHYS [$1]: $(wc -l < "$OUT/dns.$1" | tr -d ' ')"
}
