# gpu-fan backend: NVIDIA (proprietary driver, nvidia-smi)
#
# A backend is a bash file defining two functions:
#   gpu_temp_once INDEX            print ONE integer: max temperature (°C) of the
#                                  selected GPUs, exit non-zero on failure
#   gpu_temp_stream INTERVAL INDEX print one line per INTERVAL seconds, forever:
#                                  an integer (max °C) or "ERR". Must be a single
#                                  long-running process tree (no per-tick forks)
#                                  and must flush every line.
# INDEX is "all" or a comma separated list of GPU indexes.

_nv_sel() { [[ $1 == all ]] && return; printf -- '-i\n%s\n' "$1"; }

gpu_temp_once() {
  local -a sel; mapfile -t sel < <(_nv_sel "$1")
  timeout 10 nvidia-smi "${sel[@]}" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null |
    awk 'BEGIN { m = -1 } { gsub(/[[:space:]]/, "") } /^[0-9]+$/ { if ($0 + 0 > m) m = $0 + 0; next } { bad = 1 }
         END { if (bad || m < 0) exit 1; print m }'
}

gpu_temp_stream() {
  local interval=$1 n
  local -a sel; mapfile -t sel < <(_nv_sel "$2")
  # number of GPUs = lines per sample; nvidia-smi -l prints one line per GPU each loop
  n=$(timeout 10 nvidia-smi "${sel[@]}" --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c .)
  (( n > 0 )) || { echo ERR; return 1; }
  nvidia-smi "${sel[@]}" --query-gpu=temperature.gpu --format=csv,noheader,nounits -l "$interval" 2>/dev/null |
    awk -v n="$n" 'BEGIN { m = -1 }
      { v = $0; gsub(/[[:space:]]/, "", v)
        if (v ~ /^[0-9]+$/) { if (v + 0 > m) m = v + 0 } else bad = 1
        if (++c >= n) { print (bad ? "ERR" : m); fflush(); c = 0; m = -1; bad = 0 } }'
}
