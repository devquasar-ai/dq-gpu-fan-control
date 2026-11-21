#!/usr/bin/env bash
# gpu-fan installer. Run from the repository directory as root.
#   sudo ./install.sh --gpu nvidia --pwm it8689:2 [--profile normal] [--it87] [--no-start]
set -euo pipefail
cd "$(dirname "$0")"

BIN=/usr/local/bin/gpu-fan
LIB=/usr/local/lib/gpu-fan
ETC=/etc/gpu-fan
UNIT=/etc/systemd/system/gpu-fan.service

die() { echo "install: $*" >&2; exit 1; }
usage() {
  cat <<USAGE
usage: sudo ./install.sh --gpu BACKEND [--pwm CHIP:CHANNEL] [--profile NAME] [--it87] [--no-start]

  --gpu BACKEND       GPU temperature source: $(for f in gpu/*.sh; do f=${f##*/}; printf "%s " "${f%.sh}"; done)
  --pwm CHIP:CHANNEL  fan header, e.g. it8689:2 (required on first install;
                      find it with: sudo ./gpu-fan list / sudo ./gpu-fan identify)
  --profile NAME      silent | normal | performance (default: normal)
  --it87              also load the it87 driver at boot with ignore_resource_conflict=1
                      (Gigabyte and other ITE Super I/O boards; the out-of-tree driver
                      is needed for IT8686E/IT8689E, see README)
  --no-start          install and enable, but do not (re)start the service now
USAGE
}

GPU="" PWM="" PROFILE="" IT87=0 START=1
while (( $# )); do
  case $1 in
    --gpu) GPU=${2:-}; shift 2 ;;
    --pwm) PWM=${2:-}; shift 2 ;;
    --profile) PROFILE=${2:-}; shift 2 ;;
    --it87) IT87=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $EUID == 0 ]] || die "run as root: sudo $0 $*"
[[ -n $GPU ]] || { usage >&2; die "--gpu is required"; }
[[ $GPU =~ ^[a-z0-9_-]+$ && -f gpu/$GPU.sh ]] || die "unknown GPU backend '$GPU'"
case $GPU in nvidia) command -v nvidia-smi >/dev/null || die "nvidia-smi not found - install the NVIDIA driver first" ;; esac
if [[ -n $PWM ]]; then
  [[ $PWM =~ ^([A-Za-z0-9_-]+):([1-9])$ ]] || die "--pwm must look like CHIP:CHANNEL, e.g. it8689:2"
  CHIP=${BASH_REMATCH[1]} CHAN=${BASH_REMATCH[2]}
elif [[ ! -f $ETC/gpu-fan.conf ]]; then
  die "--pwm CHIP:CHANNEL is required on first install (see: sudo ./gpu-fan list)"
fi
if [[ -n $PROFILE ]]; then
  [[ -f profiles/$PROFILE.conf || -f $ETC/profiles/$PROFILE.conf ]] || die "unknown profile '$PROFILE'"
fi

echo "installing gpu-fan ..."
install -Dm755 gpu-fan "$BIN"
install -d "$LIB/gpu" "$LIB/profiles" "$ETC/profiles"
rm -f "$LIB"/gpu/*.sh "$LIB"/profiles/*.conf
install -m644 gpu/*.sh "$LIB/gpu/"
install -m644 profiles/*.conf profiles/custom.example "$LIB/profiles/"
install -Dm644 systemd/gpu-fan.service "$UNIT"

set_key() {  # key value
  if grep -q "^$1=" "$ETC/gpu-fan.conf"; then sed -i "s|^$1=.*|$1=$2|" "$ETC/gpu-fan.conf"
  else echo "$1=$2" >> "$ETC/gpu-fan.conf"; fi
}
if [[ ! -f $ETC/gpu-fan.conf ]]; then
  install -m644 gpu-fan.conf.example "$ETC/gpu-fan.conf"; echo "  created $ETC/gpu-fan.conf"
else echo "  keeping existing $ETC/gpu-fan.conf"; fi
set_key GPU_BACKEND "$GPU"
[[ -n $PWM ]] && { set_key PWM_CHIP "$CHIP"; set_key PWM_CHANNEL "$CHAN"; }
[[ -n $PROFILE ]] && set_key PROFILE "$PROFILE"

if (( IT87 )); then
  echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/gpu-fan-it87.conf
  echo "it87" > /etc/modules-load.d/gpu-fan-it87.conf
  echo "  it87 will load at boot (ignore_resource_conflict=1)"
  lsmod | grep -q '^it87 ' || modprobe it87 ignore_resource_conflict=1 || echo "  WARNING: modprobe it87 failed (see README: IT8686E/IT8689E need the out-of-tree driver)"
fi

"$BIN" profile --show >/dev/null || die "configuration is invalid - fix $ETC/gpu-fan.conf"
echo "  config: $(grep -E '^(GPU_BACKEND|PWM_CHIP|PWM_CHANNEL|PROFILE)=' "$ETC/gpu-fan.conf" | tr '\n' ' ')"

systemctl daemon-reload
systemctl enable gpu-fan.service >/dev/null 2>&1
if (( START )); then
  systemctl restart gpu-fan.service
  sleep 4
  "$BIN" status || true
fi
cat <<MSG

done. Next steps:
  sudo gpu-fan selftest          # verify temperature reading and fan control
  watch -n1 gpu-fan status       # live view
  sudo gpu-fan profile silent    # switch profile
  journalctl -u gpu-fan -f       # daemon log
MSG
