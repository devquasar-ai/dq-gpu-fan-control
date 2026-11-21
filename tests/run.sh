#!/usr/bin/env bash
# gpu-fan test suite: logic simulation + end-to-end daemon runs against a fake
# hwmon directory and a fake GPU backend. No root, no hardware needed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/gpu-fan
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; [[ -n ${KEEP:-} ]] && cp "$T/log" "$KEEP"; rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
eq() { [[ $1 == "$2" ]] || { echo "       expected '$2' got '$1'"; return 1; }; }

# --- fake environment -------------------------------------------------------
setup() {
  rm -rf "${T:?}"/*
  mkdir -p "$T/hwmon/hwmon0" "$T/hwmon/hwmon1" "$T/lib" "$T/etc" "$T/run"
  echo k10temp > "$T/hwmon/hwmon0/name"
  H=$T/hwmon/hwmon1
  echo it8689_32020507 > "$H/name"; echo 2 > "$H/pwm2_enable"; echo 128 > "$H/pwm2"; echo 1000 > "$H/fan2_input"
  cp -r "$ROOT/gpu" "$ROOT/profiles" "$T/lib/"
  cat > "$T/lib/gpu/fake.sh" <<'EOF'
gpu_temp_once() { local t; read -r t < "$FAKE_TEMP"; [[ $t =~ ^[0-9]+$ ]] && echo "$t"; }
gpu_temp_stream() {
  local t
  while :; do
    read -r t < "$FAKE_TEMP"
    case $t in EXIT) return 0 ;; HANG) sleep 1000 ;; esac
    echo "$t"; sleep "$1"
  done
}
EOF
  cat > "$T/etc/gpu-fan.conf" <<EOF
GPU_BACKEND=fake
PWM_CHIP=it8689
PWM_CHANNEL=2
PROFILE=normal
INTERVAL=1
EOF
  echo 40 > "$T/temp"
  export GPU_FAN_LIB=$T/lib GPU_FAN_CONF=$T/etc/gpu-fan.conf GPU_FAN_HWMON_ROOT=$T/hwmon \
         GPU_FAN_STATE_DIR=$T/run FAKE_TEMP=$T/temp
}
pwm() { local v; read -r v < "$H/pwm2"; echo "$v"; }
en()  { local v; read -r v < "$H/pwm2_enable"; echo "$v"; }
raw() { echo $(( $1 * 255 / 100 )); }
wait_for() { local i; for (( i = 0; i < ${2:-50}; i++ )); do eval "$1" && return 0; sleep 0.2; done; return 1; }
start() { "$BIN" run > "$T/log" 2>&1 & DPID=$!; wait_for '[[ -s $T/run/state ]]'; }
stop()  { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }

echo "== config validation"
setup
for bad_line in 'PWM_CHANNEL=12' 'INTERVAL=0' 'FAILSAFE_PCT=20' 'PROFILE=../x' 'GPU_BACKEND=$(id)' 'FOO=1' 'just garbage'; do
  cp "$T/etc/gpu-fan.conf" "$T/c.bak"; echo "$bad_line" >> "$T/etc/gpu-fan.conf"
  check "rejects: $bad_line" bash -c "! '$BIN' run >/dev/null 2>&1"
  cp "$T/c.bak" "$T/etc/gpu-fan.conf"
done
for c in 'CURVE="50:40 40:30"' 'CURVE="40:130"' 'CURVE=""' 'MIN_PCT=101' 'STOP_BELOW=50
START_AT=45'; do
  printf '%s\n' "$c" > "$T/p.conf"
  check "rejects profile: ${c//$'\n'/ }" bash -c "! '$BIN' profile --show '$T/p.conf' >/dev/null 2>&1"
done

echo "== logic (simulate)"
out=$(printf '40\n60\n85\nERR\n' | "$BIN" simulate normal | awk '{print $2}' | tr '\n' ' ')
check "normal curve 40/60/85/ERR -> 30 55 100 100" eq "$out" "30 55 100 100 "
out=$(printf '35\n45\n46\n46\n46\n46\n39\n' | "$BIN" simulate silent | awk '{print $2}' | tr '\n' ' ')
check "silent stop / hysteresis / kick" eq "$out" "0 0 60 60 25 25 0 "
out=$(printf '50 900\n50 900\n50 900\n50 0\n50 0\n50 0\n50 0\n40 900\n' | "$BIN" simulate normal 2>/dev/null | tail -1)
check "stall latches failsafe" eq "$out" "40 100 stalled"

echo "== daemon"
setup
start
check "daemon starts, manual mode" wait_for '[[ $(en) == 1 ]]'
check "40C -> 30%" wait_for '[[ $(pwm) == $(raw 30) ]]'
echo 70 > "$T/temp"
check "70C -> 75%" wait_for '[[ $(pwm) == $(raw 75) ]]'
echo 90 > "$T/temp"
check "90C (>= CRIT_TEMP) -> 100%" wait_for '[[ $(pwm) == 255 ]]'
echo 40 > "$T/temp"
check "ramps down gradually (not instantly)" wait_for '(( $(pwm) < 255 && $(pwm) > $(raw 50) ))'
echo 2 > "$H/pwm2_enable"
check "re-asserts manual mode if BIOS takes over" wait_for '[[ $(en) == 1 ]]'
echo garbage > "$T/temp"
check "bad reading -> failsafe 100%" wait_for '[[ $(pwm) == 255 ]]'
echo 40 > "$T/temp"
check "recovers after bad reading" wait_for '[[ $(pwm) == $(raw 30) ]]'

out=$("$BIN" status)
check "status shows running/profile/temp/rpm" bash -c "grep -q running <<<'$out' && grep -q 'profile    normal' <<<'$out' && grep -q '40°C' <<<'$out' && grep -q '1000 RPM' <<<'$out'"

"$BIN" profile performance >/dev/null && kill -HUP "$DPID"
check "profile switch + SIGHUP reload -> performance 50% @40C" wait_for '[[ $(pwm) == $(raw 50) ]]'
check "reload logged" grep -q 'reload: profile=performance' "$T/log"

echo "PWM_CHANNEL=12" >> "$T/etc/gpu-fan.conf"; kill -HUP "$DPID"; sleep 1.5
check "invalid config on reload is ignored, daemon keeps running" kill -0 "$DPID"
sed -i '/PWM_CHANNEL=12/d' "$T/etc/gpu-fan.conf"

echo EXIT > "$T/temp"
check "reader exits -> failsafe 100%" wait_for '[[ $(pwm) == 255 ]]'
echo 40 > "$T/temp"
check "reader restarted, back to curve" wait_for '[[ $(pwm) == $(raw 50) ]]' 60

echo HANG > "$T/temp"
check "reader hangs -> timeout -> failsafe" wait_for '[[ $(pwm) == 255 ]]' 75
echo 40 > "$T/temp"; pkill -f "sleep 1000" 2>/dev/null

echo 0 > "$H/fan2_input"
check "fan stall (0 RPM) -> latched failsafe" wait_for 'grep -q "fan stalled" "$T/log"' 60
check "status shows stalled" wait_for '"$BIN" status | grep -q stalled'
echo 1000 > "$H/fan2_input"

echo 30 > "$H/pwm2"
stop
check "SIGTERM -> failsafe 100% on exit" eq "$(pwm)" 255
check "state file removed on exit" bash -c "[[ ! -e '$T/run/state' ]]"
check "status reports not running" bash -c "'$BIN' status | grep -q 'not running'"

echo 30 > "$H/pwm2"
"$BIN" failsafe >/dev/null
check "'gpu-fan failsafe' (systemd ExecStopPost) -> 100%" eq "$(pwm)" 255
echo "GARBAGE LINE" >> "$T/etc/gpu-fan.conf"; echo 30 > "$H/pwm2"
"$BIN" failsafe >/dev/null 2>&1
check "failsafe works even with a broken config" eq "$(pwm)" 255
sed -i '/GARBAGE/d' "$T/etc/gpu-fan.conf"

"$BIN" release >/dev/null
check "release -> BIOS auto mode (enable=2)" eq "$(en)" 2

echo "== custom profile"
cp "$ROOT/profiles/custom.example" "$T/mine.conf"
"$BIN" profile --custom "$T/mine.conf" >/dev/null
check "custom profile installed + activated" bash -c "[[ -f '$T/etc/profiles/mine.conf' ]] && grep -q '^PROFILE=mine' '$T/etc/gpu-fan.conf'"
check "custom profile listed as active" bash -c "'$BIN' profile | grep -q '^\* mine'"
check "custom cannot shadow built-in name" bash -c "! '$BIN' profile --custom '$T/mine.conf' silent >/dev/null 2>&1"
printf 'CURVE="40:30"\nrm -rf /\n' > "$T/evil.conf"
check "custom profile with code is rejected" bash -c "! '$BIN' profile --custom '$T/evil.conf' >/dev/null 2>&1"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
