# Shared helpers. Every module's run.sh sources this, so a reader learns one
# set of commands rather than thirteen.
#
#   ./run.sh deploy | verify | clean
#
# NS defaults to the module's own namespace so modules never collide and any
# one of them can be run on its own.
set -uo pipefail
: "${KUBECONFIG:=$HOME/.crc/machines/crc/kubeconfig}"
export KUBECONFIG
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# assert <description> <expected> <actual>
# Verification is a set of assertions rather than a wall of output, so a module
# either passes or tells you exactly which claim failed.
FAILED=0
assert() {
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1 — expected [$2], got [$3]"; FAILED=$((FAILED+1)); fi
}
assert_contains() {
  case "$3" in (*"$2"*) ok "$1" ;; (*) bad "$1 — [$3] does not contain [$2]"; FAILED=$((FAILED+1)) ;; esac
}
summary() {
  if [ "$FAILED" -eq 0 ]; then say "all checks passed"; else say "$FAILED check(s) failed"; fi
  return "$FAILED"
}

# A namespace deleted with --wait=false is still Terminating for a while, and
# creating objects in it fails with "object has been deleted". Wait it out
# before recreating, or deploy races clean.
ns_ensure() {
  for _ in $(seq 1 60); do
    phase=$($KUBE get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Terminating" ] || break
    sleep 2
  done
  $KUBE get ns "$NS" >/dev/null 2>&1 || $KUBE create ns "$NS" >/dev/null
}

# Fatal on failure. An earlier version swallowed the error and the caller went
# on to print "up" over a namespace that had nothing in it - a green tick on a
# broken deploy is worse than no check at all.
wait_ready() {
  if ! $KUBE rollout status "deploy/$1" -n "$NS" --timeout="${2:-180s}" >/dev/null 2>&1; then
    bad "deploy/$1 never became ready in $NS"
    $KUBE get pods -n "$NS" -l "app=$1" 2>/dev/null | sed 's/^/      /'
    exit 1
  fi
}

# Envoy's STRICT_DNS resolves on a timer, so a proxy that started before its
# backend was ready answers "no healthy upstream" for the first few seconds.
# Deployment readiness does not cover that - Envoy is ready, its upstream is
# not - so wait for the cluster to actually have a member before asserting.
wait_upstream() {
  cluster=$1; svc=${2:-envoy}; tries=${3:-30}
  for _ in $(seq 1 "$tries"); do
    if incluster_curl "http://$svc.$NS.svc:9901/clusters" 2>/dev/null \
         | grep -q "^${cluster}::[0-9].*::cx_total"; then
      ok "upstream $cluster has endpoints"; return 0
    fi
    sleep 2
  done
  bad "upstream $cluster never got an endpoint"; exit 1
}

# Run a curl from inside the cluster. Nothing in these modules requires an
# Ingress or a Route, so they work the same on kind as on OpenShift.
incluster_curl() {
  $KUBE run "curl-$RANDOM" -n "$NS" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 -- -sS --max-time 10 "$@" 2>/dev/null
}
