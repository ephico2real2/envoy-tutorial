# Helpers for the modules Argo CD keeps (16, 17, 18, 19). Source after lib.sh.
#
# Each of those modules has an Argo CD Application, named after its folder
# (../argocd/), that applies the module's manifests from git and puts back
# anything that differs - a deleted object, an edited field - in under a second,
# or up to five minutes after a repair it has just made (measured). That is what keeps the lab permanent - and what would undo a clean, or
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

# app_pause <app>... - turn automated sync off, so Argo CD leaves the lab alone,
# and return only once the controller has seen the change and no sync operation
# is pending or running. Turning automated sync off stops new syncs; it does not
# stop one already under way, which could re-create what a clean deletes next.
# Five minutes at most per Application; then it fails, and so does the caller,
# before anything is deleted.
app_pause() {
  local app state observed refresh pending phase idle attempt
  for app in "$@"; do
    state=$(app_automated "$app") || exit 1
    [ -n "$state" ] || continue
    # The refresh request rides on the same patch: the controller removes the
    # annotation once it has compared with automated sync off.
    $KUBE patch applications.argoproj.io "$app" -n "$ARGOCD_NS" --type=merge \
      -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}},"spec":{"syncPolicy":{"automated":{"enabled":false}}}}' >/dev/null \
      || { bad "Argo CD Application $app could not be paused"; exit 1; }
    idle=
    for attempt in $(seq 0 150); do
      observed=$($KUBE get applications.argoproj.io "$app" -n "$ARGOCD_NS" \
        -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}{"|"}{.operation.sync}{"|"}{.status.operationState.phase}') \
        || { bad "cannot check whether Argo CD Application $app is idle"; exit 1; }
      IFS='|' read -r refresh pending phase <<<"$observed"
      if [ -z "$refresh" ] && [ -z "$pending" ]; then
        case "$phase" in (Running | Terminating) ;; (*) idle=yes; break ;; esac
      fi
      [ "$attempt" -eq 150 ] || sleep 2
    done
    [ "$idle" = yes ] \
      || { bad "Argo CD Application $app is paused but not idle after 5 minutes - nothing deleted"; exit 1; }
    if [ "$state" = off ]; then ok "Argo CD Application $app is already paused"
    else ok "Argo CD Application $app paused: it no longer puts back what changes"; fi
  done
}

# app_resume <app> - turn automated sync back on, ask for a fresh comparison, and
# wait - ten minutes at most - until Argo CD reports Synced: everything that
# differed from git has been put back. Ten minutes covers the self-heal back-off
# (at most 300 s before a repair starts) plus the repair and its status. Healthy
# is waited for too, but Synced alone passes at the deadline: module 16's
# Subscription is Progressing, not Healthy, while an operator upgrade waits for
# its manual approval (Argo CD's Subscription health check), and the lab still
# runs meanwhile - that is for a person to decide, not for this wait. A failed
# request or read fails: an old status must never pass for a new one.
app_resume() {
  local app=$1 state status='' attempt
  state=$(app_automated "$app") || exit 1
  [ -n "$state" ] || return 0
  if [ "$state" = off ]; then
    $KUBE patch applications.argoproj.io "$app" -n "$ARGOCD_NS" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"enabled":true}}}}' >/dev/null \
      || { bad "Argo CD Application $app could not be resumed"; exit 1; }
  fi
  # The status is read only once the controller has removed this request (the
  # annotation's value is then empty), so it is a comparison made after it.
  $KUBE annotate applications.argoproj.io "$app" -n "$ARGOCD_NS" --overwrite \
    argocd.argoproj.io/refresh=normal >/dev/null \
    || { bad "cannot ask Argo CD to compare Application $app again"; exit 1; }
  for attempt in $(seq 0 120); do
    status=$($KUBE get applications.argoproj.io "$app" -n "$ARGOCD_NS" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}{.status.sync.status}/{.status.health.status}') \
      || { bad "cannot read the status of Argo CD Application $app"; exit 1; }
    [ "$status" = Synced/Healthy ] && break
    [ "$attempt" -eq 120 ] || sleep 5
  done
  case "$status" in
    Synced/Healthy) ok "Argo CD Application $app resumed: Synced/Healthy - it keeps the lab as git declares it" ;;
    Synced/*) ok "Argo CD Application $app resumed: Synced"
              echo "  note: its health is ${status#Synced/} - oc get application $app -n $ARGOCD_NS -o jsonpath='{.status.resources}'" ;;
    *) bad "Argo CD Application $app resumed, but not Synced after 10 minutes ($status) - oc get application $app -n $ARGOCD_NS -o yaml"
       exit 1 ;;
  esac
}
