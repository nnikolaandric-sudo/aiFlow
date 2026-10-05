#!/bin/bash
# Counts the `git status -uall` runs triggered by a folder-bounce pattern.
#
#   ./tools/perf-bounce/count-git.sh <path/to/aiFlow.app> [rounds]
#
# Counters:
#   1. in-app trace — exact; needs a build with the FF_GIT_TRACE hook
#      (GitService.traceFullStatus / ffTraceReload) and the display AWAKE
#      (macOS stops delivering `open -a` events to a sleeping/locked session,
#      which silently yields 0 navigations and a meaningless 0).
#   2. fast pgrep sampler — works on any build, but can miss short processes,
#      so treat it as a lower bound.
set -uo pipefail

APP="${1:?usage: count-git.sh <path/to/aiFlow.app> [rounds]}"
ROUNDS="${2:-3}"
TRACE="$(mktemp -t gittrace.XXXXXX)"
SAMPLED="$(mktemp -t gitpids.XXXXXX)"

pkill -f "MacOS/aiFlow" 2>/dev/null; sleep 1
# LaunchServices-launched apps nasljeđuju launchd okolinu, pa se brojač
# pali preko launchctl setenv.
launchctl setenv FF_GIT_TRACE "$TRACE"
open "$APP"; sleep 3

# Fast sampler: 20 ms poll so a ~180 ms `git status` ne može promašiti.
( for _ in $(seq 1 3000); do
    pgrep -f "usr/bin/git" >> "$SAMPLED" 2>/dev/null
    sleep 0.02
  done ) &
SAMPLER=$!

for _ in $(seq 1 "$ROUNDS"); do
    for d in Downloads Desktop Documents Downloads; do
        open -a "$APP" "$HOME/$d" 2>/dev/null
        sleep 0.7
    done
done

sleep 1
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
launchctl unsetenv FF_GIT_TRACE 2>/dev/null
pkill -f "MacOS/aiFlow" 2>/dev/null

NAV=$((ROUNDS * 4))
RUNS=$(awk -F'\t' '$3=="ran"{n++} END{print n+0}' "$TRACE" 2>/dev/null)
SKIPS=$(awk -F'\t' '$3=="skipped"{n++} END{print n+0}' "$TRACE" 2>/dev/null)
PIDS=$(sort -u "$SAMPLED" 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')

printf '\n=== %s ===\n' "$APP"
printf 'navigacija:                    %s\n' "$NAV"
if [ -s "$TRACE" ]; then
  printf 'git status -uall (tacno, u app): %s   (preskočeno: %s)\n' "$RUNS" "$SKIPS"
else
  printf 'git status -uall (tacno, u app): —   (ovaj build nema brojač)\n'
fi
printf 'git procesa (pgrep, donja granica): %s\n' "$PIDS"
printf 'folderi u trace-u: %s\n' "$(awk -F'\t' '{print $2}' "$TRACE" 2>/dev/null | sort -u | tr '\n' ' ')"
rm -f "$TRACE" "$SAMPLED"
