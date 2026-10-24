#!/usr/bin/env bash
# Reproduces one gate-lab interaction observed while validating
# fm/fm-external-merge-teardown-20261023-r2: the new automatic-cleanup call
# (bin/fm-merge-outcome-lib.sh fm_merge_outcome_run_teardown) passes
# FM_DATA_OVERRIDE, which bin/fm-gate-refuse-lib.sh's marked-lab-home allowance
# does not accept, so the guarded cleanup is refused inside a lab home.
#
# Each case runs the real bin/fm-teardown.sh against a fresh marked lab home.
set -u
ROOT=/home/aki/.no-mistakes/worktrees/bab179a0832d/01M5PA00KH86TKVSZKS1KQ81GG
URL=https://github.com/o/r/pull/1
BASE_PATH=${ORIG_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin}

setup_case() {  # <name> -> sets LAB WT PROJ HEAD_SHA
  LAB=$(mktemp -d "/tmp/fm-lab-gate-$1.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  mkdir -p "$LAB/tmux" "$LAB/treehouse"
  PROJ="$LAB/proj"
  git init -q --bare "$LAB/origin.git"
  git init -q "$PROJ"
  git -C "$PROJ" commit -q --allow-empty -m init
  git -C "$PROJ" branch -M main
  git -C "$PROJ" remote add origin "$LAB/origin.git"
  git -C "$PROJ" push -q -u origin main
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$PROJ" fetch -q origin
  printf 'max_trees = 4\nroot = "%s"\n' "$LAB/treehouse" > "$PROJ/treehouse.toml"
  git -C "$PROJ" add treehouse.toml
  git -C "$PROJ" commit -q -m "in-lab pool root"
  git -C "$PROJ" push -q origin main
  git -C "$PROJ" fetch -q origin
  WT=$(cd "$PROJ" && TREEHOUSE_ROOT="$LAB/treehouse" treehouse get --lease -b fm/task 2>/dev/null)
  printf 'x\n' > "$WT/f.txt"
  git -C "$WT" add f.txt
  git -C "$WT" commit -q -m work
  git -C "$WT" push -q origin HEAD:refs/heads/main
  git -C "$WT" fetch -q origin
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  cat > "$LAB/state/task-a.meta" <<EOF
window=firstmate:fm-task-a
endpoint_task_id=task-a
worktree=$WT
project=$PROJ
kind=ship
mode=local-only
branch=fm/task
spawn_gen=gate-lab-probe-task-a
pr_head=$HEAD_SHA
pr=$URL
EOF
  printf 'done: PR %s checks green\n' "$URL" > "$LAB/state/task-a.status"
  touch "$LAB/state/.last-watcher-beat"
  TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n fm-task-a -c "$WT" bash
}

teardown_case() {
  ( cd "$ROOT" && TMUX_TMPDIR="$LAB/tmux" "$@" "$ROOT/bin/fm-teardown.sh" task-a ) 2>&1 | grep -E '^(fm-gate-refuse|REFUSED|error:|teardown task-a complete)' || true
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null
  rm -rf "$LAB"
}

export PATH="$BASE_PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE NO_MISTAKES_GATE

echo "=== case 1: FM_HOME only (no supervision overrides)"
setup_case home-only
teardown_case env -u FM_HOME FM_HOME="$LAB"

echo "=== case 2: the redundant overrides minus FM_DATA_OVERRIDE (root/state/config)"
setup_case no-data
teardown_case env -u FM_HOME FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"

echo "=== case 3: the exact environment the new automatic cleanup passes (adds FM_DATA_OVERRIDE)"
setup_case with-data
teardown_case env -u FM_HOME FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
  FM_DATA_OVERRIDE="$LAB/data"
