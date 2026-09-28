#!/usr/bin/env bash
# vendor.sh <envoy-grpc-modernization checkout> [commit] - write this module's copy of
# the shop into manifests/, from the app repository at <commit> (default 1e3ad13):
#
#   ./vendor.sh ~/gitRepos/envoy-grpc-modernization 1e3ad13
#
# The shop is the app repository's own code and manifests, not a fork: every file this
# writes is either one of its manifests with the namespace changed to envoy-19, or a
# ConfigMap built from one of its source files - the way its demo.sh builds them. The
# only other change: the kiosk's OpenShift Route is left out, because this module's way
# in is the Gateway. To take a newer version of the shop, run this with the new commit
# and read the diff. Nothing here needs a cluster.
set -euo pipefail
cd "$(dirname "$0")"
src=${1:-}
rev=${2:-1e3ad13}
if [ -z "$src" ] || ! git -C "$src" rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2
fi
full=$(git -C "$src" rev-parse "$rev")
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# header <what it is> - the first lines of every file written here.
header() {
  printf '# %s\n' "$1"
  printf '# Vendored by ../vendor.sh from github.com/ephico2real2/envoy-grpc-modernization\n'
  printf '# at %s. Do not edit here: change the app repository, then run vendor.sh.\n' "$full"
}
# show <path> - one file of the app repository, as it is at the commit.
show() { git -C "$src" show "$rev:$1"; }
# manifest <app file> <file here> <what it is> - the app's manifest, in namespace envoy-19.
manifest() {
  { header "$3"; show "$1" | sed 's/^\(  *\)namespace: modernize-demo$/\1namespace: envoy-19/'; } > "manifests/$2"
  ! grep -q modernize-demo "manifests/$2" || { echo "vendor.sh: $2 still names modernize-demo" >&2; exit 1; }
}
# configmap <name> <file here> <what it is> <key=app path>... - a ConfigMap of source
# files, as demo.sh creates it (oc create configmap --from-file). A file that is not
# UTF-8, the proto descriptor, goes under binaryData.
configmap() {
  local name=$1 out=$2 what=$3 args=() kv; shift 3
  for kv in "$@"; do
    show "${kv#*=}" > "$tmp/${kv%%=*}"
    args+=("--from-file=${kv%%=*}=$tmp/${kv%%=*}")
  done
  { header "$what"
    $KUBE create configmap "$name" -n envoy-19 "${args[@]}" --dry-run=client -o yaml \
      | grep -v '^  creationTimestamp: null$'; } > "manifests/$out"
}

manifest manifests/05-database.yaml  21-shop-database.yaml  "The shop's MongoDB, its claim and Service (the app's layer 0). NOTE: the app's
# comment below speaks of its demo.sh, which generates the password; this module commits a
# published LAB value in 20-shop-db-secret.yaml instead, so Argo CD can keep the Secret."
configmap inventory-src 22-shop-inventory-src.yaml "The inventory service's source: the gRPC server and its generated stubs." \
  server.py=app/server.py inventory_pb2.py=app/inventory_pb2.py inventory_pb2_grpc.py=app/inventory_pb2_grpc.py
manifest manifests/10-inventory.yaml 23-shop-inventory.yaml "The inventory service: gRPC only, three replicas, a headless Service (layer 1)."
manifest manifests/20-envoy-config.yaml 24-shop-envoy-config.yaml "The shop's own Envoy: REST+JSON to gRPC with grpc_json_transcoder."
configmap envoy-proto 25-shop-envoy-proto.yaml "The compiled proto descriptor the shop's Envoy transcodes with (binary)." \
  inventory.pb=proto/inventory.pb
manifest manifests/30-envoy.yaml     26-shop-envoy.yaml     "The shop's own Envoy as a Deployment and Service (layer 2)."
configmap kiosk-src 27-shop-kiosk-src.yaml "The kiosk: one browser page that speaks REST and JSON only." \
  index.html=kiosk/index.html
# The kiosk's Deployment and Service - its manifest's first two documents. The third,
# the Route to the shop's Envoy, is the way in module 20 takes, not this one.
manifest manifests/40-kiosk.yaml     28-shop-kiosk.yaml     "The kiosk's web server (layer 3). The app's Route is left out: the Gateway is the way in."
awk '/^---$/ { n++ } n < 2' "manifests/28-shop-kiosk.yaml" > "$tmp/kiosk" && mv "$tmp/kiosk" "manifests/28-shop-kiosk.yaml"
! grep -q 'kind: Route' manifests/28-shop-kiosk.yaml || { echo "vendor.sh: the kiosk's Route is still there" >&2; exit 1; }
echo "vendored envoy-grpc-modernization $full into manifests/2[1-8]-shop-*.yaml"
