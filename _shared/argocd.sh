# Helpers for the modules Argo CD keeps (16, 17, 18). Source after lib.sh.
#
# Each of those modules has an Argo CD Application, named after its folder
# (../argocd/), that applies the module's manifests from git and puts back, in
# about a second (measured), anything that differs: a deleted object, an edited
# field. That is what keeps the lab permanent - and what would undo a clean, or
# a walkthrough step that changes an object on purpose, as it happens. Pausing
# turns the Application's automated sync off (spec.syncPolicy.automated.enabled);
# it keeps comparing, so it shows OutOfSync, but changes nothing until resumed.
# On a cluster without the Application every helper here does nothing.

ARGOCD_NS=openshift-gitops

# app_automated <app> - "on" or "off" for the Application's automated sync, or
# nothing when there is no such Application. Fatal on any other error, such as
# Forbidden: a clean that cannot see the Application cannot pause it, and Argo CD
# would undo the clean.
app_automated() {
  local out
  if out=$($KUBE get applications.argoproj.io "$1" -n "$ARGOCD_NS" \
             -o jsonpath='{.spec.syncPolicy.automated}' 2>&1); then
    case "$out" in ("" | *'"enabled":false'*) echo off ;; (*) echo on ;; esac
    return 0
  fi
  case "$out" in (*NotFound* | *"doesn't have a resource type"*) return 0 ;; esac
  # To stderr: callers read this function's stdout as the answer.
  bad "cannot read Argo CD Application $1: $out" >&2
  return 1
}

# app_pause <app>... - turn automated sync off, so Argo CD leaves the lab alone.
app_pause() {
  local app state
  for app in "$@"; do
    state=$(app_automated "$app") || exit 1
    case "$state" in
      "")  ;;
      off) ok "Argo CD Application $app is already paused" ;;
      on)  $KUBE patch applications.argoproj.io "$app" -n "$ARGOCD_NS" --type=merge \
             -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}' >/dev/null \
             || { bad "Argo CD Application $app could not be paused"; exit 1; }
           ok "Argo CD Application $app paused: it no longer puts back what changes" ;;
    esac
  done
}

# app_resume <app> - turn automated sync back on, and wait - five minutes at most -
# until Argo CD has compared again and reports Synced: everything that differed
# from git has been put back. Healthy is waited for too, but Synced alone passes:
# module 16's Subscription is Progressing, not Healthy, while an operator upgrade
# waits for its manual approval (Argo CD's Subscription health check), and the
# lab still runs meanwhile - that is for a person to decide, not for this wait.
app_resume() {
  local app=$1 state status=
  state=$(app_automated "$app") || exit 1
  [ -n "$state" ] || return 0
  if [ "$state" = off ]; then
    $KUBE patch applications.argoproj.io "$app" -n "$ARGOCD_NS" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"enabled":true}}}}' >/dev/null \
      || { bad "Argo CD Application $app could not be resumed"; exit 1; }
  fi
  # A status read before the controller has compared again could be the old one:
  # ask for a refresh, and read the status only once the controller has removed
  # the request (the annotation's value is then empty).
  $KUBE annotate applications.argoproj.io "$app" -n "$ARGOCD_NS" --overwrite \
    argocd.argoproj.io/refresh=normal >/dev/null
  for _ in $(seq 1 60); do
    status=$($KUBE get applications.argoproj.io "$app" -n "$ARGOCD_NS" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}{.status.sync.status}/{.status.health.status}')
    [ "$status" = Synced/Healthy ] && break
    sleep 5
  done
  case "$status" in
    Synced/Healthy) ok "Argo CD Application $app resumed: Synced/Healthy - it keeps the lab as git declares it" ;;
    Synced/*) ok "Argo CD Application $app resumed: Synced"
              echo "  note: its health is ${status#Synced/} - oc get application $app -n $ARGOCD_NS -o jsonpath='{.status.resources}'" ;;
    *) bad "Argo CD Application $app resumed, but not Synced after 5 minutes ($status) - oc get application $app -n $ARGOCD_NS -o yaml"
       exit 1 ;;
  esac
}
