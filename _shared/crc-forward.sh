#!/usr/bin/env bash
# crc-forward.sh - forward a port on the laptop to an address on the CRC VM's network,
# through CRC's own network proxy (gvproxy). CRC only - see below.
#
#   crc-forward.sh ensure <127.0.0.1:port> <ip:port>   forward the laptop's port to that address
#   crc-forward.sh remove <127.0.0.1:port> [<ip:port>] stop forwarding it - with <ip:port>, only
#                                                      when it forwards there (a caller's own)
#   crc-forward.sh get <127.0.0.1:port>                where the port forwards to, or nothing
#   crc-forward.sh list                                every forward, as "<local> -> <remote>"
#
# Why: MetalLB gives a Gateway an address on the CRC VM's network (192.168.127.0/24), which
# the laptop does not route to. CRC's gvproxy carries the laptop's traffic into that network,
# and forwards a few ports by itself (:80 and :443 to the router, 127.0.0.1:6443 to the API
# server, 127.0.0.1:2222 to ssh, and the podman socket). Its HTTP API, on the unix socket
# ~/.crc/sockets/crc-http.sock, adds and removes more (/network/services/forwarder/...). On
# bare metal a MetalLB address is on a network the clients route to: no forward is needed.
#
# ensure is idempotent: nothing to do when the same forward exists; a failure when the port
# already forwards somewhere else, or when another program listens on it. remove never
# touches CRC's own forwards, and with <ip:port> leaves a forward of the same port to
# another address alone and fails (someone else's). A forward list that cannot be read is
# a failure, never "not forwarded". A forward lasts until it is removed or CRC's VM stops - it does
# not survive `crc stop` / `crc start` (the forwards live in the running gvproxy); run the
# module's `./run.sh deploy` again after a restart.
#
# Exit status: 0 done, 1 refused or failed, 2 usage, 3 no CRC socket (not CRC, or CRC down).
set -euo pipefail
SOCK=${CRC_HTTP_SOCK:-$HOME/.crc/sockets/crc-http.sock}
API=http://crc/network/services/forwarder
# CRC's own forwards, never removed here.
BUILTIN=" :80 :443 127.0.0.1:6443 127.0.0.1:2222 $HOME/.crc/machines/crc/docker.sock "

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
fail() { echo "crc-forward.sh: $*" >&2; exit 1; }

[ -S "$SOCK" ] || {
  echo "crc-forward.sh: no CRC network socket at $SOCK - this helper is for OpenShift Local (CRC)" \
       "only, and CRC must be running. Elsewhere a MetalLB address is reached directly." >&2
  exit 3
}

# forwards - every forward gvproxy holds, one "<local> <remote>" per line.
forwards() {
  curl -sf --unix-socket "$SOCK" "$API/all" \
    | python3 -c 'import json, sys; [print(f["local"], f["remote"]) for f in json.load(sys.stdin)]' 2>/dev/null \
    || fail "cannot read CRC's forwards from $SOCK"
}
# remote_of <local> - where <local> forwards to, or nothing.
remote_of() { forwards | awk -v l="$1" '$1 == l { print $2 }'; }
# post <path> <json> - one request to gvproxy's forwarder API; fails unless it answers 200.
post() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -X POST -d "$2" "$API/$1") || code=000
  [ "$code" = 200 ] || fail "gvproxy refused $1 $2 (HTTP $code)"
}
local_ok()  { [[ $1 =~ ^127\.0\.0\.1:[0-9]{1,5}$ ]]; }
remote_ok() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]]; }

case "${1:-}" in
  ensure)
    if [ $# -ne 3 ] || ! local_ok "$2" || ! remote_ok "$3"; then usage; fi
    # A failed read is a failure, never "not forwarded": the proxy's state is unknown.
    now=$(remote_of "$2") || fail "cannot read CRC's forwards - nothing changed"
    if [ "$now" = "$3" ]; then echo "$2 -> $3: already forwarded"; exit 0; fi
    [ -z "$now" ] || fail "$2 already forwards to $now, not $3 - remove it first: crc-forward.sh remove $2"
    # Another program on the laptop listening on the port would take the connections.
    port=${2##*:}
    # lsof exits 1 when nothing listens: that is the answer wanted, not an error.
    busy=$({ lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR > 1 { print $1 " (pid " $2 ")" }' | sort -u | paste -sd' ' -)
    [ -z "$busy" ] || fail "port $port is taken on this laptop by $busy - pick another port"
    post expose "{\"local\":\"$2\",\"remote\":\"$3\",\"protocol\":\"tcp\"}"
    now=$(remote_of "$2") || fail "forwarded $2 -> $3, but cannot read CRC's forwards to check it"
    [ "$now" = "$3" ] || fail "gvproxy accepted $2 -> $3, but does not list it"
    echo "$2 -> $3: forwarded" ;;
  remove)
    if [ $# -lt 2 ] || [ $# -gt 3 ] || ! local_ok "$2" || { [ $# -eq 3 ] && ! remote_ok "$3"; }; then usage; fi
    case "$BUILTIN" in (*" $2 "*) fail "$2 is one of CRC's own forwards - left alone" ;; esac
    now=$(remote_of "$2") || fail "cannot read CRC's forwards - nothing removed"
    [ -n "$now" ] || { echo "$2: not forwarded"; exit 0; }
    if [ $# -eq 3 ] && [ "$now" != "$3" ]; then
      fail "$2 forwards to $now, not $3 - not yours, left alone"
    fi
    post unexpose "{\"local\":\"$2\",\"protocol\":\"tcp\"}"
    now=$(remote_of "$2") || fail "asked to remove $2, but cannot read CRC's forwards to check it"
    [ -z "$now" ] || fail "gvproxy accepted the removal of $2, but still lists it"
    echo "$2: forward removed" ;;
  get)
    if [ $# -ne 2 ] || ! local_ok "$2"; then usage; fi
    remote_of "$2" || fail "cannot read CRC's forwards" ;;
  list)
    [ $# -eq 1 ] || usage
    forwards | awk '{ print $1 " -> " $2 }' ;;
  *) usage ;;
esac
