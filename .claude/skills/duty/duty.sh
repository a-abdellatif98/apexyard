#!/usr/bin/env bash
# Deterministic helper for the /duty skill. See SKILL.md for the contract.
set -uo pipefail

die() { printf 'duty: %s\n' "$*" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cfg_num() {
  local key="$1" fallback="$2" v=""
  if [ -n "${DUTY_CONFIG_JSON:-}" ]; then
    v=$(printf '%s' "$DUTY_CONFIG_JSON" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
  fi
  printf '%s' "${v:-$fallback}"
}

cmd_state_dir_check() {
  local dir="$1" probe="$1"
  [ -n "$dir" ] || die "state dir is empty"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ] && [ -n "$probe" ]; do
    probe=$(dirname "$probe")
  done
  if git -C "$probe" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'INSIDE_REPO %s\n' "$(git -C "$probe" rev-parse --show-toplevel)"
    return 1
  fi
  printf 'OK\n'
}

cmd_init() {
  local state="$1" scope="${2:-$(iso_now)}"
  [ -f "$state" ] && die "state file exists: $state"
  mkdir -p "$(dirname "$state")"
  jq -n --arg s "$scope" '{
    shift: {scope_timestamp: $s, started: $s},
    last_watcher_tick: null, last_review_tick: null,
    items: {}, actions: [], proposals_seen: []
  }' > "$state"
}

cmd_liveness() {
  local state="$1" now="${2:-$(iso_now)}"
  local w_stale r_stale
  w_stale=$(cfg_num watcher_stale_minutes 45)
  r_stale=$(cfg_num review_stale_minutes 90)
  jq -r --arg now "$now" --argjson ws "$w_stale" --argjson rs "$r_stale" '
    def age($f): if .[$f] == null then null
      else (((($now | fromdateiso8601) - (.[$f] | fromdateiso8601)) / 60) | floor) end;
    if .shift.scope_timestamp == null then "NO_SHIFT"
    else
      [ (age("last_watcher_tick") as $a
          | if $a == null then "NEVER watcher"
            elif $a > $ws then "STALE watcher \($a)" else empty end),
        (age("last_review_tick") as $a
          | if $a == null then empty
            elif $a > $rs then "STALE review \($a)" else empty end) ]
      | if length == 0 then "OK" else .[] end
    end' "$state"
}

cmd_plan() {
  local state="$1" now="${2:-$(iso_now)}" interval
  interval=$(cfg_num review_interval_minutes 30)
  local due
  due=$(jq -r --arg now "$now" --argjson iv "$interval" '
    if .last_review_tick == null then "yes"
    elif ((($now | fromdateiso8601) - (.last_review_tick | fromdateiso8601)) / 60) >= $iv
    then "yes" else "no" end' "$state")
  printf '%s\n' liveness watcher stamp_watcher
  [ "$due" = "yes" ] && printf '%s\n' review stamp_review
  printf '%s\n' report journal
}

cmd_verify_tick() {
  local log="$1"
  local -a steps=()
  local s
  while IFS= read -r s; do
    [ -n "$s" ] && steps+=("$s")
  done < "$log"
  local i idx_live=-1 idx_watch=-1 idx_wstamp=-1 idx_review=-1
  for i in "${!steps[@]}"; do
    case "${steps[$i]}" in
      liveness)      [ "$idx_live" -lt 0 ] && idx_live=$i ;;
      watcher)       [ "$idx_watch" -lt 0 ] && idx_watch=$i ;;
      stamp_watcher) [ "$idx_wstamp" -lt 0 ] && idx_wstamp=$i ;;
      review)        [ "$idx_review" -lt 0 ] && idx_review=$i ;;
    esac
  done
  [ "$idx_live" -eq 0 ] || { echo "FAILED liveness gate did not run first"; return 1; }
  [ "$idx_watch" -ge 0 ] || { echo "FAILED watcher pass skipped"; return 1; }
  [ "$idx_wstamp" -gt "$idx_watch" ] || { echo "FAILED watcher stamp missing or before watcher"; return 1; }
  if [ "$idx_review" -ge 0 ] && [ "$idx_review" -lt "$idx_wstamp" ]; then
    echo "FAILED review ran before the watcher stamp"; return 1
  fi
  echo "OK"
}

cmd_stamp() {
  local state="$1" which="$2" at="${3:-$(iso_now)}" field tmp
  case "$which" in
    watcher) field=last_watcher_tick ;;
    review)  field=last_review_tick ;;
    *) die "stamp: watcher|review" ;;
  esac
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg f "$field" --arg at "$at" '.[$f] = $at' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_record_action() {
  local state="$1" item="$2" action="$3" at="${4:-$(iso_now)}" tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg i "$item" --arg a "$action" --arg at "$at" \
    '.actions += [{item: $i, action: $a, at: $at}]' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_fetch_status() {
  local rc="$1" count="$2" limit="$3"
  if [ "$rc" != "0" ]; then echo "UNKNOWN"; return 0; fi
  case "$count" in ''|*[!0-9]*) echo "UNKNOWN"; return 0 ;; esac
  if [ "$count" -lt "$limit" ]; then echo "COMPLETE"; else echo "TRUNCATED"; fi
}

cmd_partition() {
  local items="$1" state="$2" me="$3"
  jq -n --slurpfile items "$items" --slurpfile st "$state" --arg me "$me" '
    ($st[0].shift.scope_timestamp) as $scope
    | ($st[0].actions | map(select(.at >= $scope)) | map(.item) | unique) as $acted
    | ($items[0] | if type == "array" then . else [] end)
    | map(
        . as $it
        | [ { name: "new_in_scope",
              v: (if $it.created == null or $it.assignee_known == false then null
                  else (($it.created >= $scope)
                        and (($it.assignee_id // "") == "" or $it.assignee_id == $me)) end) },
            { name: "mine_new_comment",
              v: (if $it.assignee_known == false then null
                  else ($it.assignee_id == $me
                        and (($it.last_comment_at // "") >= $scope)
                        and (($it.last_comment_author_id // $me) != $me)) end) },
            { name: "acted_this_shift",
              v: ($acted | index($it.id) != null) },
            { name: "reviewer_waiting",
              v: (if $it.unresolved_known == false then null
                  else (($it.unresolved_waiting_on_me // 0) > 0) end) } ]
        | { id: $it.id,
            matched: map(select(.v == true) | .name),
            unknown: map(select(.v == null) | .name),
            owned: (map(select(.v == true)) | length > 0) }
      )'
}

item_set() {
  local state="$1" id="$2" to="$3" reason="$4" tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq --arg id "$id" --arg to "$to" --arg r "$reason" --arg at "$(iso_now)" '
    .items[$id] = ((.items[$id] // {}) + {state: $to, since: $at, reason: $r})
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

cmd_item() {
  local state="$1" id="$2" event="$3" actor="${4:-loop}" reason="${5:-}"
  local cur
  cur=$(jq -r --arg id "$id" '.items[$id].state // "none"' "$state")
  case "$event:$cur" in
    escalate:none|escalate:closed) item_set "$state" "$id" open "$reason" ;;
    escalate:open|escalate:parked) echo "$cur"; return 0 ;;
    park:open)
      [ "$actor" = "operator" ] || { echo "REFUSED only the operator parks an item"; return 1; }
      item_set "$state" "$id" parked "$reason" ;;
    unpark:parked)
      [ "$actor" = "operator" ] || { echo "REFUSED only the operator unparks an item"; return 1; }
      item_set "$state" "$id" open "$reason" ;;
    close:open|close:parked) item_set "$state" "$id" closed "$reason" ;;
    *) echo "REFUSED $event from $cur"; return 1 ;;
  esac
  jq -r --arg id "$id" '.items[$id].state' "$state"
}

cmd_nag() {
  jq -r '.items | to_entries | map(select(.value.state == "open")) | .[].key' "$1"
}

cmd_handover_items() {
  jq -r '.items | to_entries
    | map(select(.value.state == "open" or .value.state == "parked"))
    | .[] | "\(.value.state)\t\(.key)\t\(.value.reason // "")"' "$1"
}

section_of() {
  local playbook="$1" text="$2"
  DUTY_NEEDLE="$text" awk '
    BEGIN { needle = ENVIRON["DUTY_NEEDLE"] }
    /^## / { sec = $0; prot = 0 }
    /<!-- duty:protected -->/ { prot = 1 }
    { buf[sec] = buf[sec] "\n" $0; p[sec] = p[sec] || prot }
    END { for (s in buf) if (index(buf[s], needle) > 0) { print (p[s] ? "PROTECTED" : "OPEN") "\t" s; exit } }
  ' "$playbook"
}

cmd_classify() {
  local proposal="$1" playbook="$2"
  local declared old new reasons=()
  declared=$(jq -r '.class // "B"' "$proposal")
  old=$(jq -r '.old // ""' "$proposal")
  new=$(jq -r '.new // ""' "$proposal")

  [ "$declared" = "A" ] || reasons+=("declared class $declared")

  local loc
  if [ -n "$old" ]; then
    loc=$(section_of "$playbook" "$old")
    if [ -z "$loc" ]; then
      reasons+=("old text not found in playbook")
    elif [ "${loc%%	*}" = "PROTECTED" ]; then
      reasons+=("RAIL: edits protected section ${loc#*	}")
    fi
  else
    local anchor
    anchor=$(jq -r '.section // ""' "$proposal")
    loc=$(DUTY_ANCHOR="$anchor" awk '
      BEGIN { s = ENVIRON["DUTY_ANCHOR"] }
      /^## / { cur = $0; prot = 0 }
      /<!-- duty:protected -->/ { prot = 1 }
      cur == s && prot { print "PROTECTED"; exit }
      cur == s { found = 1 }
      END { if (found) print "OPEN" }' "$playbook" | head -1)
    [ "$loc" = "PROTECTED" ] && reasons+=("RAIL: adds to protected section $anchor")
    [ -z "$loc" ] && reasons+=("target section not found")
  fi

  local norm='(never|always|must|do not|don.t|only|halt|stop|escalate|approval|gate|required)'
  local removed
  removed=$(printf '%s\n' "$old" | grep -iE "$norm" | while IFS= read -r l; do
    printf '%s\n' "$new" | grep -qF -- "$l" || printf '%s\n' "$l"
  done)
  [ -n "$removed" ] && reasons+=("RAIL: removes or rewrites a normative line")

  local old_nums new_nums
  old_nums=$(printf '%s' "$old" | grep -oE '[0-9]+' | sort | tr '\n' ' ')
  new_nums=$(printf '%s' "$new" | grep -oE '[0-9]+' | sort | tr '\n' ' ')
  if [ -n "$old" ] && [ "$old_nums" != "$new_nums" ]; then
    reasons+=("RAIL: changes a number (threshold, cadence, or limit)")
  fi

  local widen='(unattended|without (operator|approval|asking)|skip|disable|relax|loosen|redundant|no longer (need|require)|auto-?(approve|merge|resolve)|drop the (check|gate))'
  if printf '%s' "$new" | grep -qiE "$widen"; then
    reasons+=("RAIL: new text widens unattended action or removes a check")
  fi

  if [ "${#reasons[@]}" -eq 0 ]; then
    echo "A"
  else
    echo "B"
    printf '  %s\n' "${reasons[@]}"
  fi
}

cmd_apply() {
  local proposal="$1" playbook="$2" approval="${3:-}"
  local verdict
  verdict=$(cmd_classify "$proposal" "$playbook" | head -1)
  if [ "$verdict" != "A" ] && [ "$approval" != "--operator-approved" ]; then
    echo "REFUSED class $verdict needs operator approval"
    return 1
  fi
  local old new section tmp
  old=$(jq -r '.old // ""' "$proposal")
  new=$(jq -r '.new // ""' "$proposal")
  section=$(jq -r '.section // ""' "$proposal")
  tmp=$(mktemp) || die "mktemp failed"
  if [ -z "$old" ]; then
    DUTY_ANCHOR="$section" DUTY_NEW="$new" awk '
      BEGIN { s = ENVIRON["DUTY_ANCHOR"]; n = ENVIRON["DUTY_NEW"] }
      /^## / && in_s { print n; print ""; done = 1; in_s = 0 }
      /^## / && $0 == s { in_s = 1 }
      { print }
      END { if (in_s) { print ""; print n; done = 1 } if (!done) exit 3 }
    ' "$playbook" > "$tmp" || { rm -f "$tmp"; echo "REFUSED section not found"; return 1; }
    mv "$tmp" "$playbook"
    echo "APPLIED"
    return 0
  fi
  OLD="$old" NEW="$new" perl -0777 -pe '
    BEGIN { $o = $ENV{OLD}; $n = $ENV{NEW}; $c = 0 }
    $c = () = /\Q$o\E/g;
    die "old text matched $c times, need exactly 1\n" unless $c == 1;
    s/\Q$o\E/$n/;
  ' "$playbook" > "$tmp" || { rm -f "$tmp"; echo "REFUSED old text is not unique"; return 1; }
  mv "$tmp" "$playbook"
  echo "APPLIED"
}

main() {
  need_jq
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    state-dir-check) cmd_state_dir_check "$@" ;;
    init)            cmd_init "$@" ;;
    liveness)        cmd_liveness "$@" ;;
    plan)            cmd_plan "$@" ;;
    verify-tick)     cmd_verify_tick "$@" ;;
    stamp)           cmd_stamp "$@" ;;
    record-action)   cmd_record_action "$@" ;;
    fetch-status)    cmd_fetch_status "$@" ;;
    partition)       cmd_partition "$@" ;;
    item)            cmd_item "$@" ;;
    nag)             cmd_nag "$@" ;;
    handover-items)  cmd_handover_items "$@" ;;
    classify)        cmd_classify "$@" ;;
    apply)           cmd_apply "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
