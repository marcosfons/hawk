#!/bin/bash
#
# perf.sh - measure a release Hawk (build/Hawk.app) in one scenario.
#
#   tools/perf.sh <scenario>        (or: make perf SCENARIO=<scenario>)
#   tools/perf.sh list
#
# For one scenario it: quits any running Hawk (remembering which), launches
# build/Hawk.app set up for the scenario, waits for it to settle, then records
#   - CPU, memory and energy (POWER) from `top`, averaged over the run
#   - `footprint` at the start and the end
#   - `sample` for 10 s, summarised as busy samples per thread
#   - `leaks` (soak only)
#   - phone side, when a device is connected and the adb server is already up:
#     adbd / sh / app_process / logcat CPU from the phone's `top`, and anything
#     of Hawk's left running there
# and writes build/perf/<date>-<scenario>.md. The Hawk that was running before
# is reopened at the end (KEEP=1 leaves the measured one running instead).
#
# Read-only on the phone. It never starts or restarts the adb server.
#
# Environment: DURATION (seconds measured, default per scenario), WARMUP
# (seconds before measuring, default 20), ANDROID_SERIAL (which phone), KEEP=1.
#
# Adding a scenario: one line in `scenario` below (tab, window, duration),
# plus an entry in `list`.

set -u
export LC_ALL=C   # decimal points, not commas, in every number
cd "$(dirname "$0")/.." || exit 1

APP="$PWD/build/Hawk.app"
EXE="$APP/Contents/MacOS/Hawk"
OUT_DIR="$PWD/build/perf"
WARMUP="${WARMUP:-20}"

die() { echo "perf: $*" >&2; exit 1; }

FAKE_PORT=5099
FAKE_ENV=(--env "ADB=$PWD/tools/fake-adb" --env "ANDROID_ADB_SERVER_PORT=$FAKE_PORT")

# scenario NAME -> TAB (feature id), WINDOW (open|closed), SECS, WHAT, and optionally
# ENVS (open --env pairs) and ACTION (a function run when measuring starts).
scenario() {
    ENVS=(); ACTION=""; XARGS=()
    case "$1" in
        baseline)   TAB=overview; WINDOW=open;   SECS=60;   WHAT="Window open on Overview" ;;
        background) TAB=overview; WINDOW=closed; SECS=60;   WHAT="Window closed, menu bar only" ;;
        soak)       TAB="${TAB:-overview}"; WINDOW=open; SECS=1800; WHAT="Soak with the window open on $TAB, footprint every minute, leaks at the end" ;;
        android-closed) TAB=overview; WINDOW=open; SECS=60; WHAT="Window open on Overview, Android tab closed, adb running, device connected" ;;
        # Fake adb on a spare port (tools/fake-adb): the real server and the phone are never touched.
        android-overview) TAB=android; WINDOW=open; SECS=60; XARGS=(-androidSection overview)
                    WHAT="Android tab open on Overview, phone on USB: one shell batch every 3 s" ;;
        adb-down)   TAB=android; WINDOW=open; SECS=60; ENVS=("${FAKE_ENV[@]}" --env FAKE_ADB_FAIL=1)
                    WHAT="Android tab open, adb cannot start (fake adb): backoff, then failing with 60 s retries" ;;
        adb-restart) TAB=overview; WINDOW=closed; SECS=30; ENVS=("${FAKE_ENV[@]}"); ACTION=kill_fake_server
                    WHAT="Server killed by someone else (fake adb) as measuring starts; the 30 s of recovery after" ;;
        *) return 1 ;;
    esac
    SECS="${DURATION:-$SECS}"
}

list() {
    cat <<'EOF'
baseline     window open on Overview, 60 s
background   window closed (menu bar only), 60 s
soak         window open (TAB=<feature id>, default overview), 30 min, leaks
android-closed  window open on Overview, adb running, device connected, 60 s
android-overview  Android tab on a device's Overview, phone on USB, 60 s (phone CPU matters)
adb-down     Android tab open, adb failing to start (fake adb, port 5099), 60 s
adb-restart  window closed, fake adb server killed as measuring starts, 30 s of recovery

Scenarios with the window open need it uncovered on the current desktop for the
whole run (a minimized window or one on another desktop measures as hidden), so
they only run with WINDOW_OK=1, when nobody is using the screen.
EOF
}

[ $# -eq 1 ] || { echo "usage: tools/perf.sh <scenario> | list" >&2; list >&2; exit 2; }
[ "$1" = list ] && { list; exit 0; }
NAME="$1"
scenario "$NAME" || { echo "perf: unknown scenario '$NAME'" >&2; list >&2; exit 2; }
[ -x "$EXE" ] || die "no $APP; run make first"
[ "$WINDOW" = closed ] || [ "${WINDOW_OK:-0}" = 1 ] ||
    die "$NAME needs the Hawk window uncovered for the whole run; run it with WINDOW_OK=1 when the screen is free"

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y-%m-%d-%H%M)"
REPORT="$OUT_DIR/$STAMP-$NAME.md"
TMP="$(mktemp -d "$OUT_DIR/.run.XXXXXX")"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"

hawk_pids() { pgrep -f '/Hawk.app/Contents/MacOS/Hawk( |$)'; }

# Quit every running Hawk, remembering the bundle of the first one to reopen later.
PREVIOUS=""
for pid in $(hawk_pids); do
    exe="$(ps -o command= -p "$pid")"
    [ -z "$PREVIOUS" ] && PREVIOUS="${exe%%/Contents/MacOS/Hawk*}"
done
if [ -n "$(hawk_pids)" ]; then
    echo "perf: quitting the running Hawk ($PREVIOUS); it is reopened at the end"
    osascript -e 'quit app id "com.marcos.Hawk"' >/dev/null 2>&1
    for _ in $(seq 20); do [ -z "$(hawk_pids)" ] && break; sleep 0.5; done
    for pid in $(hawk_pids); do kill "$pid"; done
    sleep 1
    [ -z "$(hawk_pids)" ] || die "could not quit the running Hawk"
fi

kill_fake_server() { pkill -f "fake-adb-server.py $FAKE_PORT"; }

PID=""
CAFFEINATE=""
LOGSTREAM=""
cleanup() {
    [ -n "$CAFFEINATE" ] && kill "$CAFFEINATE" 2>/dev/null
    [ -n "$LOGSTREAM" ] && kill "$LOGSTREAM" 2>/dev/null
    if [ "${KEEP:-0}" != 1 ] && [ -n "$PID" ]; then
        osascript -e 'quit app id "com.marcos.Hawk"' >/dev/null 2>&1
        for _ in $(seq 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        kill "$PID" 2>/dev/null
        if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ]; then
            sleep 1
            # -g: in the background, never in front of what the user is doing.
            open -g "$PREVIOUS" && echo "perf: reopened $PREVIOUS (in the background)"
        fi
    fi
    [ ${#ENVS[@]} -gt 0 ] && kill_fake_server
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Started before Hawk, so its launch (adb attach or start) is in the report too.
/usr/bin/log stream --style compact --level info \
    --predicate 'subsystem == "com.marcos.Hawk" AND category == "app"' >"$TMP/log" 2>/dev/null & LOGSTREAM=$!
sleep 1

ARGS=(-feature "$TAB" ${XARGS[@]+"${XARGS[@]}"})
[ "$WINDOW" = closed ] && ARGS+=(-startInMenuBar YES)
echo "perf: $NAME - $WHAT (commit $COMMIT)"
open -n -g ${ENVS[@]+"${ENVS[@]}"} "$APP" --args "${ARGS[@]}" || die "could not open $APP"
for _ in $(seq 20); do PID="$(pgrep -f "^$EXE( |$)" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] || die "Hawk did not start"

# The display must stay awake: a sleeping display or a covered window reads as background.
caffeinate -d -i -w "$PID" & CAFFEINATE=$!

echo "perf: Hawk $PID, settling for $WARMUP s"
sleep "$WARMUP"
kill -0 "$PID" 2>/dev/null || die "Hawk exited during warm-up"

footprint_mb() { footprint "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1 |
    awk '{ v=$1; if ($2=="KB") v/=1024; if ($2=="GB") v*=1024; printf "%.1f", v }'; }

# Phone side, only when adb's server is already listening (never start it from here).
phone_serial() {
    command -v adb >/dev/null || return 1
    nc -z 127.0.0.1 5037 2>/dev/null || return 1
    if [ -n "${ANDROID_SERIAL:-}" ]; then echo "$ANDROID_SERIAL"; return 0; fi
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" { print $1; exit }' | grep .
}
SERIAL="$(phone_serial)"

FP_START="$(footprint_mb "$PID")"
LOG_START="$(wc -l <"$TMP/log")"
[ -n "$ACTION" ] && "$ACTION"

# Samples every second (every 10 s for long runs); the first sample has no CPU yet.
STEP=1; [ "$SECS" -gt 300 ] && STEP=10
COUNT=$(( SECS / STEP + 1 ))
top -l "$COUNT" -s "$STEP" -pid "$PID" -stats pid,cpu,mem,power >"$TMP/top" 2>/dev/null & TOP=$!

if [ -n "$SERIAL" ]; then
    # Three phone readings 5 s apart while the Mac side is measured; the first is since boot.
    adb -s "$SERIAL" shell top -b -n 3 -d 5 -o PID,%CPU,RES,ARGS >"$TMP/phone-top" 2>&1 &
    PHONE=$!
fi

if [ "$NAME" = soak ]; then
    : >"$TMP/footprints"
    for (( m = 1; m * 60 <= SECS; m++ )); do
        sleep 60
        kill -0 "$PID" 2>/dev/null || die "Hawk exited during the soak"
        echo "$m $(footprint_mb "$PID")" >>"$TMP/footprints"
        echo "perf: minute $m, footprint $(tail -1 "$TMP/footprints" | cut -d' ' -f2) MB"
    done
fi
wait "$TOP"
[ -n "${PHONE:-}" ] && wait "$PHONE"
kill -0 "$PID" 2>/dev/null || die "Hawk exited during the run"
FP_END="$(footprint_mb "$PID")"

# CPU and POWER averaged over every sample but the first; MEM as top shows it last.
read -r CPU POWER MEM < <(awk -v pid="$PID" '$1 == pid { n++; if (n > 1) { c += $2; p += $4; k++ } m = $3 }
    END { if (k) printf "%.2f %.2f %s\n", c / k, p / k, m; else print "? ? ?" }' "$TMP/top")

echo "perf: sampling for 10 s"
sample "$PID" 10 -mayDie -file "$TMP/sample" >/dev/null 2>&1

# Busy samples per thread: leaves of the call graph that are not a wait in the kernel.
awk '
    /^Call graph:/ { in_graph = 1; next }
    in_graph && /^Total number in stack/ { in_graph = 0 }
    !in_graph { next }
    {
        match($0, /[0-9]+ /); if (RSTART == 0) next
        depth = RSTART; rest = substr($0, RSTART); split(rest, f, " "); count = f[1] + 0
        name = substr(rest, length(f[1]) + 2)
        if (depth == 5 && name ~ /^Thread_/) {
            flush(); thread = name; sub(/^Thread_([0-9]+|<multiple>):? */, "", thread); if (thread == "") thread = "(unnamed)"
            total = count; idle = 0; pend = ""; next
        }
        if (pend != "" && depth <= pdepth) leaf(pend, pcount)
        pend = name; pcount = count; pdepth = depth
    }
    function leaf(n, c) { if (n ~ /^(mach_msg2?_trap|__psynch_cvwait|__psynch_mutexwait|__workq_kernreturn|kevent|kevent64|kevent_id|__semwait_signal|__select|poll|read|__recvfrom|__accept|__wait4|__sigsuspend|start_wqthread)( |$)/) idle += c }
    function flush() {
        if (thread == "") return
        if (pend != "") leaf(pend, pcount)
        printf "| %s | %d | %d |\n", thread, total, total - idle
        pend = ""; thread = ""
    }
    END { flush() }
' "$TMP/sample" >"$TMP/threads"
MAIN_BUSY="$(awk -F'|' '/Main Thread|main-thread/ { gsub(/ /, "", $4); print $4; exit }' "$TMP/threads")"
ALL_BUSY="$(awk -F'|' '{ gsub(/ /, "", $4); s += $4 } END { print s + 0 }' "$TMP/threads")"

if [ "$NAME" = soak ]; then
    echo "perf: running leaks"
    leaks "$PID" >"$TMP/leaks" 2>&1
    LEAKS="$(sed -n 's/.*: \([0-9][0-9]*\) leaks for .*/\1/p' "$TMP/leaks" | head -1)"
    LEAKS="${LEAKS:-? (see leaks output)}"
    DRIFT="$(awk 'NR == 1 { a = $2 } { b = $2 } END { printf "%+.1f", b - a }' "$TMP/footprints")"
fi

PHONE_CPU="-"
if [ -n "$SERIAL" ]; then
    # Toybox top: a header per iteration, %CPU of one core, ARGS last. Iterations 2 and 3 only.
    PHONE_CPU="$(awk '
        /Tasks:/ { it++; next }
        it >= 2 && ($4 ~ /(adbd|app_process|logcat)/ || $4 ~ /(^|\/)sh$/) { c += $2 }
        END { if (it >= 2) printf "%.1f", c / (it - 1); else print "?" }
    ' "$TMP/phone-top")"
    PHONE_LEFT="$(adb -s "$SERIAL" shell 'ps -A -o PID,ARGS' 2>/dev/null | grep -i hawk | grep -v grep)"
fi

# Visibility changes during the measured part only (launch itself flips it once or twice).
HIDDEN="$(tail -n +"$(( LOG_START + 1 ))" "$TMP/log" | grep -c 'Window hidden')"
VALID="yes"
[ "$WINDOW" = open ] && [ "${HIDDEN:-0}" -gt 0 ] && VALID="no: the window was covered or hidden during the run"

{
    echo "# perf: $NAME"
    echo
    echo "$WHAT. $(date '+%Y-%m-%d %H:%M'), commit $COMMIT, $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string)."
    echo "Measured ${SECS} s after ${WARMUP} s of warm-up. Valid: $VALID."
    echo
    echo "| CPU avg | Memory (top) | Footprint start | Footprint end | POWER avg | Main thread busy (10 s) | All threads busy | Phone CPU (adbd+sh+...) |"
    echo "|---|---|---|---|---|---|---|---|"
    echo "| ${CPU}% | $MEM | ${FP_START} MB | ${FP_END} MB | $POWER | ${MAIN_BUSY:-?} | $ALL_BUSY | ${PHONE_CPU}% |"
    echo
    if [ "$NAME" = soak ]; then
        echo "Soak: footprint drift ${DRIFT} MB over the run, leaks: $LEAKS."
        echo
        echo '```'; cat "$TMP/footprints"; echo '```'; echo
    fi
    if [ "${HIDDEN:-0}" -gt 0 ]; then
        echo "Window visibility changes while measured:"
        echo; echo '```'; tail -n +"$(( LOG_START + 1 ))" "$TMP/log" | grep 'Window '; echo '```'; echo
    fi
    if grep -qE 'adb|Android device' "$TMP/log"; then
        echo "adb events (whole run, warm-up included):"
        echo; echo '```'; grep -E 'adb|Android device' "$TMP/log" | sed -E 's/^[0-9-]+ ([0-9:]+)[^ ]* .*:app\] /\1 /' | cut -c1-160; echo '```'; echo
    fi
    echo "## Threads (sample, 10 s at 1 ms: total samples / busy samples)"
    echo
    echo "| Thread | Samples | Busy |"
    echo "|---|---|---|"
    sort -t'|' -k4 -rn "$TMP/threads"
    if [ -n "$SERIAL" ]; then
        echo
        echo "## Phone"
        echo
        echo '```'
        grep -E '^Tasks:|adbd|app_process|logcat| sh$' "$TMP/phone-top"
        echo '```'
        echo
        echo "Hawk processes left on the phone: ${PHONE_LEFT:-none}"
    else
        echo
        echo "Phone: not measured (no device, or the adb server was not running)."
    fi
} >"$REPORT"

echo "perf: CPU ${CPU}%  mem $MEM  footprint ${FP_START} -> ${FP_END} MB  power $POWER  main busy ${MAIN_BUSY:-?}  phone ${PHONE_CPU}%  valid: $VALID"
[ "$NAME" = soak ] && echo "perf: soak drift ${DRIFT} MB, leaks $LEAKS"
echo "perf: report $REPORT"
