#!/usr/bin/env bash
# Remove gpu-fan. The fan header is handed back to BIOS/chip automatic control.
#   sudo ./uninstall.sh [--purge]    --purge also removes /etc/gpu-fan and the it87 boot config
set -uo pipefail
[[ $EUID == 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
PURGE=0; [[ ${1:-} == --purge ]] && PURGE=1

systemctl disable --now gpu-fan.service 2>/dev/null
[[ -x /usr/local/bin/gpu-fan ]] && /usr/local/bin/gpu-fan release
rm -f /etc/systemd/system/gpu-fan.service /usr/local/bin/gpu-fan
rm -rf /usr/local/lib/gpu-fan
systemctl daemon-reload
if (( PURGE )); then
  rm -rf /etc/gpu-fan
  rm -f /etc/modprobe.d/gpu-fan-it87.conf /etc/modules-load.d/gpu-fan-it87.conf
  echo "gpu-fan removed (including configuration)"
else
  echo "gpu-fan removed (configuration kept in /etc/gpu-fan; use --purge to remove)"
fi
echo "note: the fan now follows the BIOS fan curve for this header - check it in the BIOS"
