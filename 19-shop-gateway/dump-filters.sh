#!/usr/bin/env bash
# dump-filters.sh - the HTTP filters Envoy Gateway generated for Gateway eg in envoy-19,
# as YAML on standard output: the listener's filter chain, in order, and what one route
# of the shop turns on in it. What produced generated/envoy-filters.yaml:
#
#   ./dump-filters.sh > generated/envoy-filters.yaml
#
# Read from the running Envoy's admin API (../_shared/eg-admin.sh), not from the
# manifests. Secrets appear only as the names Envoy fetches them by (SDS), never as values.
set -euo pipefail
cd "$(dirname "$0")"
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
listeners=$(../_shared/eg-admin.sh envoy-19/eg 'config_dump?resource=dynamic_listeners')
routes=$(../_shared/eg-admin.sh envoy-19/eg 'config_dump?resource=dynamic_route_configs')
version=$(../_shared/eg-admin.sh envoy-19/eg server_info | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')
image=$($KUBE get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-19,gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="envoy")].image}')
python3 - "$version" "$image" 3<<<"$listeners" 4<<<"$routes" <<'PY'
import json, re, sys

listeners = json.load(open(3))["configs"]
routes = json.load(open(4))["configs"]

def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    # Plain when YAML reads it back as the same string; JSON-quoted (valid YAML) otherwise.
    if re.fullmatch(r"[A-Za-z_/][A-Za-z0-9_./@%()-]*", v) and v not in ("true", "false", "null", "yes", "no", "on", "off"):
        return v
    return json.dumps(v)

def emit(v, indent=0):
    pad = "  " * indent
    if isinstance(v, dict):
        for k, x in v.items():
            if isinstance(x, (dict, list)) and x:
                print(f"{pad}{scalar(k)}:")
                emit(x, indent + 1)
            else:
                print(f"{pad}{scalar(k)}: {scalar(x) if not isinstance(x, (dict, list)) else ('{}' if isinstance(x, dict) else '[]')}")
    else:
        for x in v:
            if isinstance(x, dict) and x:
                lines = []
                first = True
                for k, y in x.items():
                    lead = f"{pad}- " if first else f"{pad}  "
                    first = False
                    if isinstance(y, (dict, list)) and y:
                        print(f"{lead}{scalar(k)}:")
                        emit(y, indent + 2)
                    else:
                        print(f"{lead}{scalar(k)}: {scalar(y) if not isinstance(y, (dict, list)) else ('{}' if isinstance(y, dict) else '[]')}")
            elif isinstance(x, list) and x:
                print(f"{pad}-")
                emit(x, indent + 1)
            else:
                print(f"{pad}- {scalar(x)}")

chain = None
for c in listeners:
    listener = c["active_state"]["listener"]
    if listener["name"] != "envoy-19/eg/http":
        continue
    for fc in [listener.get("default_filter_chain")] + listener.get("filter_chains", []):
        for f in (fc or {}).get("filters", []):
            if "http_filters" in f["typed_config"]:
                chain = f["typed_config"]["http_filters"]
shop_route = None
for c in routes:
    for vh in c["route_config"]["virtual_hosts"]:
        for r in vh["routes"]:
            if r["match"].get("path_separated_prefix") == "/v1":
                shop_route = {"name": r["name"], "match": r["match"],
                              "typed_per_filter_config": r["typed_per_filter_config"]}
if chain is None or shop_route is None:
    sys.exit("dump-filters.sh: no listener envoy-19/eg/http or no /v1 route - is the module deployed?")

print(f"# The HTTP filters Envoy Gateway v1.9.1 generated for Gateway eg in envoy-19, read from")
print(f"# its Envoy ({sys.argv[1]}) by ../dump-filters.sh:")
print(f"#   image {sys.argv[2]}")
print(f"#   (the image Envoy Gateway v1.9.1 pins. The shop's own Envoy, behind this one, runs")
print(f"#   the app's envoyproxy/envoy:v1.39.1 - measured 1.39.1 (pinned, #19)")
print(f"#   patches, so a later pull can be a newer 1.39.)")
print(f"#")
print(f"#   ./dump-filters.sh > generated/envoy-filters.yaml")
print(f"#")
print(f"# 1. http_filters - listener envoy-19/eg/http's chain, in the order Envoy runs it. oauth2")
print(f"#    and rbac are in it with no settings, which Envoy reads as off for a request (an")
print(f"#    OAuth2 without config, an RBAC without rules); jwt_authn holds the providers but no")
print(f"#    rules. Each route turns all three on with its own settings (2).")
print(f"# 2. route - the shop's /v1 route and what it turns on. The routes for /, /whoami,")
print(f"#    /oauth2/callback and /logout carry the same three settings (the policy targets the")
print(f"#    whole Gateway); only the route names inside them differ.")
emit({"http_filters": chain, "route": shop_route})
PY
