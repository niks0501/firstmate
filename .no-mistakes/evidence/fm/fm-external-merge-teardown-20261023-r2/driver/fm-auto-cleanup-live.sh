#!/usr/bin/env bash
# Live validation driver for fm/fm-external-merge-teardown-20261023-r2.
#
# Drives the REAL firstmate entrypoints (bin/fm-pr-merge.sh, bin/fm-watch.sh,
# bin/fm-teardown.sh, bin/fm-pr-check.sh, bin/fm-branch-prompt.sh) inside a
# marked disposable lab home minted by bin/fm-lab-home.sh: its own state/, its
# own private tmux socket (TMUX_TMPDIR), its own real treehouse pool, and a gh
# shim that stands in for GitHub (a disposable external forge, not the product).
#
# Usage: fm-auto-cleanup-live.sh <scenario>   (or "all")
set -u

ROOT=/home/aki/.no-mistakes/worktrees/bab179a0832d/01M5PA00KH86TKVSZKS1KQ81GG
EVID=/home/aki/.no-mistakes/evidence/01M5PA00KH86TKVSZKS1KQ81GG
RUN="$EVID/live"
URL=https://github.com/o/r/pull/1
ORIG_PATH=${ORIG_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin}
FAILS=0

say() { printf '%s\n' "$*"; }
ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
assert_contains() {  # <file/string-flag: file|text> <haystack> <needle> <label>
  local kind=$1 hay=$2 needle=$3 label=$4 body=
  case "$kind" in file) body=$(cat "$hay" 2>/dev/null || true) ;; *) body=$hay ;; esac
  case "$body" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label (missing: $needle)" ;;
  esac
}
assert_not_contains() {
  local kind=$1 hay=$2 needle=$3 label=$4 body=
  case "$kind" in file) body=$(cat "$hay" 2>/dev/null || true) ;; *) body=$hay ;; esac
  case "$body" in
    *"$needle"*) bad "$label (unexpected: $needle)" ;;
    *) ok "$label" ;;
  esac
}

# ---------------------------------------------------------------- fixture ---
new_lab() {  # <name> -> sets LAB
  LAB=$(mktemp -d "/tmp/fm-lab-$1.XXXXXX") || exit 1
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  mkdir -p "$LAB/tmux" "$LAB/treehouse" "$LAB/fakebin" "$LAB/out" || exit 1
  printf 'OPEN\n' > "$LAB/gh-state"
  write_gh_shim
  trap cleanup_lab EXIT
}

cleanup_lab() {
  [ "${KEEP_LAB:-}" = 1 ] && return 0
  [ -n "${LAB:-}" ] || return 0
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
  LAB=
}

write_gh_shim() {
  cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Disposable GitHub stand-in: the merge state is a file this fixture flips.
state_file=${GH_STATE_FILE:?}
state=$(cat "$state_file" 2>/dev/null || printf OPEN)
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
merged_json=$([ "$state" = MERGED ] && printf true || printf false)
case "${1:-} ${2:-}" in
  "api graphql")
    printf 'state=%s\nmerged=%s\nqueued=false\nbase=main\n' "$state" "$merged_json"
    exit 0
    ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '{"state":"%s","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' \
          "$([ "$state" = MERGED ] && printf MERGED || printf OPEN)" "${GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
        exit 0 ;;
      *" --json isDraft "*)
        printf '{"isDraft":false}\n'; exit 0 ;;
      *headRefOid,reviewDecision*)
        printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' "${GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
        exit 0 ;;
      *" -q .state "*|*" --jq .state "*|*" --json state "*)
        printf '%s\n' "$state"; exit 0 ;;
    esac
    ;;
  "pr merge")
    if [ -n "${GH_MERGE_HOOK:-}" ]; then "$GH_MERGE_HOOK"; fi
    printf 'MERGED\n' > "$state_file"
    exit 0
    ;;
esac
case " $* " in
  *" api repos/"*"/issues/"*"/comments?per_page=100 "*|*" api repos/"*"/pulls/"*"/reviews?per_page=100 "*|*" api repos/"*"/pulls/"*"/comments?per_page=100 "*)
    printf '%s\n' '[[]]' ;;
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*)
    printf '%s\n' '[{"check_runs":[]}]' ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*)
    printf '%s\n' '[[]]' ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*)
    ;;
  *" api --paginate repos/"*"/rules/branches/"*)
    printf '%s\n' '[]' ;;
  *" api repos/"*"/branches/"*)
    printf '%s\n' '{"name":"main","protected":false}' ;;
  *" api repos/"*"/pulls/"*)
    printf '{"state":"%s","user":{"login":"author"},"head":{"sha":"%s"},"draft":false,"mergeable":true,"merged_at":null}\n' \
      "$([ "$state" = MERGED ] && printf closed || printf open)" "${GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" api repos/"*)
    printf '%s\n' '{"permissions":{"push":false}}' ;;
  *" headRefOid "*) printf '%s\n' "${GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*) printf '%s\n' "$state" ;;
esac
exit 0
SH
  chmod +x "$LAB/fakebin/gh"
  cat > "$LAB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-0}"
exit 0
SH
  cat > "$LAB/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'title:\tfixture merge request\nstate:\tmerged\nauthor:\tsomeone\n'
exit 0
SH
  chmod +x "$LAB/fakebin/gh-axi" "$LAB/fakebin/glab"
  # Disposable no-mistakes stand-in: reports one terminal, passed run on the
  # fixture worktree's own head, the shape bin/fm-crew-state.sh reads.
  cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -z "${NM_LOG:-}" ] || printf '%s\n' "$*" >> "$NM_LOG"
if [ "${1:-}" = axi ] && [ "$#" -eq 1 ]; then
  head=$(git -C "${NM_WORKTREE:-.}" rev-parse HEAD 2>/dev/null) || exit 1
  printf 'repo: %s\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  RUNFIXTURE,fm/task,completed,%s,\n' \
    "${NM_WORKTREE:-.}" "$head"
  exit 0
fi
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
head=$(git -C "${NM_WORKTREE:-.}" rev-parse HEAD 2>/dev/null) || exit 1
printf 'run:\n  id: "RUNFIXTURE"\n  branch: fm/task\n  status: completed\n  head_sha: %s\noutcome: passed\n' "$head"
printf 'branch_sync:\n  state: synchronized\n  local:\n    head: %s\n  pipeline:\n    current_head: %s\n' "$head" "$head"
SH
  chmod +x "$LAB/fakebin/no-mistakes"
}

make_project() {  # -> sets PROJ WT
  PROJ="$LAB/proj"
  git init -q --bare "$LAB/origin.git" || exit 1
  git init -q "$PROJ" || exit 1
  git -C "$PROJ" commit -q --allow-empty -m init || exit 1
  git -C "$PROJ" branch -M main
  git -C "$PROJ" remote add origin "$LAB/origin.git"
  git -C "$PROJ" push -q -u origin main || exit 1
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$PROJ" fetch -q origin
  printf 'max_trees = 4\nroot = "%s"\n' "$LAB/treehouse" > "$PROJ/treehouse.toml"
  git -C "$PROJ" add treehouse.toml
  git -C "$PROJ" commit -q -m "in-lab pool root"
  git -C "$PROJ" push -q origin main || exit 1
  git -C "$PROJ" fetch -q origin
  WT=$(cd "$PROJ" && TREEHOUSE_ROOT="$LAB/treehouse" treehouse get --lease -b fm/task 2>"$LAB/out/treehouse-get.err") || {
    say "treehouse get failed:"; cat "$LAB/out/treehouse-get.err"; exit 1; }
}

land_work() {  # -> sets HEAD_SHA; lands the worktree commit on origin/main
  printf 'delivered\n' > "$WT/f.txt"
  git -C "$WT" add f.txt
  git -C "$WT" commit -q -m "deliver the lane's change"
  git -C "$WT" push -q origin HEAD:refs/heads/main || exit 1
  git -C "$WT" fetch -q origin
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
}

write_task() {  # <status-line> <extra-meta-lines...>
  local status=$1 id=task-a
  shift
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$WT"
    printf 'project=%s\n' "$PROJ"
    printf 'kind=ship\n'
    printf 'mode=%s\n' "${TASK_MODE:-no-mistakes}"
    printf 'branch=fm/task\n'
    printf 'spawn_gen=live-auto-cleanup-%s\n' "$id"
    printf 'pr_head=%s\n' "$HEAD_SHA"
    printf 'pr=%s\n' "$URL"
    printf '%s\n' "$@"
  } > "$LAB/state/$id.meta"
  printf '%s\n' "$status" > "$LAB/state/$id.status"
  touch "$LAB/state/.last-watcher-beat"
}

open_window() {
  TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n fm-task-a -c "$WT" bash || exit 1
}

product_env() {  # <scenario-dir> -- sets the environment for a real product call
  local out=$1
  export FM_HOME="$LAB"
  export GH_STATE_FILE="$LAB/gh-state"
  export GH_LOG="$out/gh.log"
  export GH_HEAD="${HEAD_SHA:-}"
  export NM_WORKTREE="${WT:-}"
  export NM_LOG="$out/no-mistakes.log"
  export PATH="$LAB/fakebin:$ORIG_PATH"
  export TMUX_TMPDIR="$LAB/tmux"
  unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE \
    FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_TASK_ID \
    REX_SESSION REX_BLOCK CMUX_WORKSPACE_ID HERDR_PANE_ID
  # A marked lab home already authorizes lifecycle; the product's own test-suite
  # seam is still armed here because the new automatic-cleanup call passes
  # FM_DATA_OVERRIDE, which bin/fm-gate-refuse-lib.sh's lab allowance rejects
  # (see finding). Nothing outside the disposable lab is reachable either way.
  if [ "${NO_BYPASS:-}" = 1 ]; then unset FM_GATE_REFUSE_BYPASS; else export FM_GATE_REFUSE_BYPASS=1; fi
}

ack_cycle() {  # drain/acknowledge one delivered supervision cycle, as a home does
  local err="$LAB/out/drain.err" seq gen
  FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" > /dev/null 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" \
      --recovery-generation "$gen" > /dev/null 2>&1 || true
  fi
}

run_watcher() {  # <output-prefix>
  local out=$1
  FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    "$ROOT/bin/fm-watch.sh" > "$out.out" 2> "$out.err"
}

# --------------------------------------------------------------- scenarios ---
scenario_self_merge() {
  local out rc
  new_lab self-merge
  out="$LAB/out"
  make_project
  land_work
  write_task "done: PR $URL checks green"
  open_window
  product_env "$out"

  set +e
  "$ROOT/bin/fm-pr-merge.sh" task-a "$URL" > "$out/merge.out" 2> "$out/merge.err"
  rc=$?
  set -e
  say "--- fm-pr-merge.sh rc=$rc"
  cat "$out/merge.out"
  [ "$rc" -eq 0 ] || { bad "self-merge entrypoint failed: $(cat "$out/merge.err")"; return; }
  assert_contains file "$out/merge.out" "check: merge landed: task-a $URL; lane automatically cleaned up" \
    "merge entrypoint output reports the automatic cleanup to its caller"
  assert_contains file "$LAB/state/.wake-queue" "check: merge landed: task-a $URL; lane automatically cleaned up" \
    "durable merge notice carries the cleanup outcome"
  [ ! -e "$LAB/state/task-a.meta" ] && [ ! -e "$LAB/state/task-a.status" ] \
    && ok "the finished lane's records were retired by the cleanup" \
    || bad "the finished lane's records survived its automatic cleanup"
  (cd "$PROJ" && treehouse status 2>/dev/null) > "$out/treehouse-status.txt" || true
  grep -q 'available' "$out/treehouse-status.txt" \
    && ok "the lane's treehouse slot was really returned to the pool" \
    || bad "the lane's worktree slot was not returned: $(cat "$out/treehouse-status.txt")"
  TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t firstmate > "$out/tmux-windows.txt" 2>&1 || true
  assert_not_contains file "$out/tmux-windows.txt" "fm-task-a" "the lane's tmux window was really closed"
  # The merge-notification marker deliberately outlives the task record: it is
  # the durable identity a later duplicate report dedupes against.
  [ -f "$LAB/state/task-a.pr-poll-merge-notified" ] \
    && ok "the merge-notification identity survived the cleanup" \
    || bad "the cleanup removed the merge-notification identity a duplicate report needs"
}

scenario_poll_merge() {
  local out rc
  new_lab poll-merge
  out="$LAB/out"
  make_project
  land_work
  write_task "done: PR $URL checks green"
  open_window
  product_env "$out"

  set +e
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" > "$out/check.out" 2> "$out/check.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { bad "arming the merge poll failed: $(cat "$out/check.err")"; return; }
  # The lane's own status write is a signal the watcher surfaces first; let a
  # first cycle consume it exactly as a live home would, then observe the merge.
  run_watcher "$out/pre"
  ack_cycle
  printf 'MERGED\n' > "$LAB/gh-state"
  set +e
  run_watcher "$out/watch"
  rc=$?
  set -e
  say "--- fm-watch.sh rc=$rc"
  [ "$rc" -eq 0 ] || { bad "watcher failed: $(tail -5 "$out/watch.err")"; return; }
  assert_contains file "$LAB/state/.wake-queue" "lane automatically cleaned up" \
    "the watcher's merge notice reports the automatic cleanup"
  [ ! -e "$LAB/state/task-a.meta" ] \
    && ok "the poll-detected merge retired the finished direct report" \
    || bad "the poll-detected merge left the finished lane in place"
  assert_contains file "$LAB/state/.wake-queue" "merged-task-a-$URL" \
    "the durable cleanup notice keeps the merge identity key"
  [ "$(grep -F "merged-task-a-$URL" "$LAB/state/.wake-queue" | tail -n 1)" ] \
    && local last; last=$(grep -F "merged-task-a-$URL" "$LAB/state/.wake-queue" | tail -n 1)
  case "$last" in
    *"check: merge landed: task-a $URL"*"lane automatically cleaned up"*)
      ok "the durable row presented for this merge key is the cleanup notice" ;;
    *) bad "the durable merge-key row is not the cleanup notice: $last" ;;
  esac
}

scenario_refused_cleanup() {
  local out rc
  new_lab refused
  out="$LAB/out"
  make_project
  land_work
  write_task "done: PR $URL checks green"
  # Uncommitted tracked work: the guarded teardown must refuse this lane.
  printf 'unlanded edit\n' >> "$WT/f.txt"
  open_window
  product_env "$out"

  set +e
  "$ROOT/bin/fm-pr-merge.sh" task-a "$URL" > "$out/merge.out" 2> "$out/merge.err"
  rc=$?
  set -e
  say "--- fm-pr-merge.sh rc=$rc"
  cat "$out/merge.out"
  [ "$rc" -eq 0 ] || bad "a refused cleanup failed the landed merge: $(tail -3 "$out/merge.err")"
  assert_contains file "$out/merge.out" "automatic cleanup refused: REFUSED:" \
    "the merge entrypoint surfaces the guarded refusal reason"
  assert_contains file "$LAB/state/.wake-queue" "automatic cleanup refused: REFUSED:" \
    "the durable notice carries the guarded refusal reason"
  [ -f "$LAB/state/task-a.meta" ] && [ -f "$LAB/state/task-a.status" ] \
    && ok "the refused lane kept its records (nothing was forced)" \
    || bad "a refused cleanup removed the lane's records"
  grep -q 'unlanded edit' "$WT/f.txt" \
    && ok "the unlanded work was not discarded by the refused cleanup" \
    || bad "the refused cleanup discarded unlanded work"
  TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t firstmate > "$out/tmux-windows.txt" 2>&1 || true
  assert_contains file "$out/tmux-windows.txt" "fm-task-a" "the refused lane's endpoint stayed open"
}

scenario_secondmate_lane() {
  local out rc
  new_lab secondmate
  out="$LAB/out"
  make_project
  land_work
  write_task "done: PR $URL checks green"
  printf 'mate-x\n' > "$LAB/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$LAB/.fm-secondmate-parent"
  open_window
  product_env "$out"

  set +e
  "$ROOT/bin/fm-pr-merge.sh" task-a "$URL" > "$out/merge.out" 2> "$out/merge.err"
  rc=$?
  set -e
  say "--- fm-pr-merge.sh (secondmate home) rc=$rc"
  cat "$out/merge.out"
  assert_not_contains file "$out/merge.out" "lane automatically cleaned up" \
    "a secondmate home's merge output keeps the plain notice"
  assert_contains file "$LAB/state/parent-replies.status" ": merged task-a $URL" \
    "the secondmate still reports the plain merge upward"
  assert_not_contains file "$LAB/state/parent-replies.status" "lane automatically cleaned up" \
    "the upward report carries no cleanup sentence"
  [ -f "$LAB/state/task-a.meta" ] && [ -f "$LAB/state/task-a.status" ] \
    && ok "the secondmate lane was not auto-torn down" \
    || bad "a secondmate home's lane was auto-torn down"
}

scenario_inflight_lane() {
  local out rc
  new_lab in-flight
  out="$LAB/out"
  make_project
  land_work
  write_task "working: running the validation pipeline"
  open_window
  product_env "$out"

  set +e
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" > "$out/check.out" 2> "$out/check.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { bad "arming the merge poll failed: $(cat "$out/check.err")"; return; }
  run_watcher "$out/pre"
  ack_cycle
  printf 'MERGED\n' > "$LAB/gh-state"
  set +e
  run_watcher "$out/watch"
  rc=$?
  set -e
  say "--- fm-watch.sh (in-flight lane) rc=$rc"
  assert_contains file "$LAB/state/.wake-queue" "check: merge landed: task-a $URL" \
    "the in-flight lane still surfaces the merge notice"
  assert_not_contains file "$LAB/state/.wake-queue" "lane automatically cleaned up" \
    "an in-flight lane keeps today's plain merge notice"
  [ -f "$LAB/state/task-a.meta" ] && [ -f "$LAB/state/task-a.status" ] \
    && ok "the in-flight lane was left in place" \
    || bad "an in-flight lane was auto-torn down"
}

scenario_deliverable_mismatch() {
  local out rc other=https://github.com/o/r/pull/2
  new_lab deliverable-mismatch
  out="$LAB/out"
  make_project
  land_work
  # The lane is finished, but the deliverable its status file names is not the
  # PR that just merged: the guarded cleanup must decline and keep the notice.
  write_task "done: PR $other checks green"
  open_window
  product_env "$out"
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" > "$out/check.out" 2> "$out/check.err" \
    || { bad "arming the merge poll failed: $(cat "$out/check.err")"; return; }
  run_watcher "$out/pre"; ack_cycle
  printf 'MERGED\n' > "$LAB/gh-state"
  run_watcher "$out/watch"; rc=$?
  say "--- fm-watch.sh (deliverable mismatch) rc=$rc"
  assert_contains file "$LAB/state/.wake-queue" "check: merge landed: task-a $URL" \
    "the merge of a lane whose status names another PR is still surfaced"
  assert_not_contains file "$LAB/state/.wake-queue" "lane automatically cleaned up" \
    "a lane without its merged deliverable on file keeps the plain notice"
  [ -f "$LAB/state/task-a.meta" ] && [ -f "$LAB/state/task-a.status" ] \
    && ok "the mismatched-deliverable lane was left in place" \
    || bad "a lane whose recorded deliverable was a different PR was cleaned up"
}

scenario_duplicate_absorption() {
  local out rc before after triage
  new_lab duplicate
  out="$LAB/out"
  make_project
  land_work
  # In-flight lane: the merge notice is surfaced but cleanup is declined, so the
  # lane (and its poll) survives for a second observation of the same merge.
  write_task "working: running the validation pipeline"
  open_window
  product_env "$out"
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" > "$out/check.out" 2> "$out/check.err" \
    || { bad "arming the merge poll failed: $(cat "$out/check.err")"; return; }
  run_watcher "$out/pre-1"; ack_cycle
  run_watcher "$out/pre-2"; ack_cycle
  printf 'MERGED\n' > "$LAB/gh-state"
  run_watcher "$out/watch-1"; rc=$?
  say "--- fm-watch.sh (first merged observation) rc=$rc"
  ack_cycle
  before=$(grep -c -F "check: merge landed: task-a $URL" "$LAB/state/.wake-queue" 2>/dev/null || true)
  # The same merge is observed again through a re-registered poll - the exact
  # path bin/fm-pr-lib.sh's notification marker exists for.
  "$ROOT/bin/fm-pr-check.sh" task-a "$URL" >> "$out/check.out" 2>> "$out/check.err" \
    || bad "re-arming the same merged PR poll was refused: $(tail -2 "$out/check.err")"
  run_watcher "$out/watch-2"; rc=$?
  say "--- fm-watch.sh (duplicate observation) rc=$rc"
  after=$(grep -c -F "check: merge landed: task-a $URL" "$LAB/state/.wake-queue" 2>/dev/null || true)
  [ "$after" = "$before" ] \
    && ok "the duplicate merged poll published no second merge notice" \
    || bad "a duplicate merged poll published another notice ($before -> $after)"
  triage="$LAB/state/.watch-triage.log"
  assert_contains file "$triage" "absorbed duplicate merged PR poll result" \
    "the watcher recognised the duplicate merge by its durable identity"
  [ -f "$LAB/state/task-a.pr-poll-merge-notified" ] \
    && ok "the merge identity stayed durable across the duplicate observation" \
    || bad "the merge identity was dropped before the duplicate arrived"
}

scenario_prompt() {
  local out rc
  new_lab prompt
  out="$LAB/out"
  product_env "$out"
  set +e
  "$ROOT/bin/fm-branch-prompt.sh" > "$out/branch-prompt.txt" 2> "$out/branch-prompt.err"
  rc=$?
  set -e
  say "--- fm-branch-prompt.sh rc=$rc bytes=$(wc -c < "$out/branch-prompt.txt")"
  assert_contains file "$out/branch-prompt.txt" "When that wake reports \`lane automatically cleaned up\`" \
    "the emitted supervision prompt covers a cleanup the merge notice reports"
}

preserve() {  # <scenario> - keep the lab's own artifacts as evidence
  local s d f
  s=$1
  d="$RUN/$s"
  mkdir -p "$d"
  cp -R "$LAB/out/." "$d/" 2>/dev/null || true
  for f in .wake-queue .watch-triage.log parent-replies.status; do
    [ ! -f "$LAB/state/$f" ] || cp "$LAB/state/$f" "$d/state.${f#.}.txt"
  done
  ls -A "$LAB/state" > "$d/state-files.txt" 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t firstmate > "$d/tmux-windows.txt" 2>&1 || true
  [ -z "${PROJ:-}" ] || (cd "$PROJ" && treehouse status) > "$d/treehouse-status.txt" 2>&1 || true
}

run_one() {
  case "$1" in
    self-merge) scenario_self_merge ;;
    poll-merge) scenario_poll_merge ;;
    refused) scenario_refused_cleanup ;;
    secondmate) scenario_secondmate_lane ;;
    in-flight) scenario_inflight_lane ;;
    deliverable-mismatch) scenario_deliverable_mismatch ;;
    duplicate) scenario_duplicate_absorption ;;
    prompt) scenario_prompt ;;
    *) say "unknown scenario $1"; exit 2 ;;
  esac
  if [ "${NO_BYPASS:-}" = 1 ]; then preserve "$1-gate-lab-refusal"; else preserve "$1"; fi
  PROJ=
  [ "${KEEP_LAB:-}" = 1 ] && say "KEEPING lab $LAB" || cleanup_lab
}

mkdir -p "$RUN"
case "${1:-all}" in
  all) for s in self-merge poll-merge refused secondmate in-flight deliverable-mismatch duplicate prompt; do
         say "===== scenario: $s"; run_one "$s"
       done ;;
  *) run_one "$1" ;;
esac
if [ "$FAILS" -gt 0 ]; then
  say "RESULT: $FAILS assertion(s) failed"
  exit 1
fi
say "RESULT: all assertions passed"
