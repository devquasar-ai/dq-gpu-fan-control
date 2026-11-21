<div align="center">
  <img src="assets/logo.png" alt="dq-gpu-fan-control — a DevQuasar project" width="220">
</div>

# dq-gpu-fan-control

Installs the `gpu-fan` command and `gpu-fan.service`.

Control a **motherboard fan header** from **GPU temperature** on Linux.

Built for passively cooled server/datacenter GPUs (Tesla, A100, CMP, MI-series, ...)
in desktop PCs: the card has no fan of its own, so you strap a fan to it with a
shroud and plug that fan into a chassis fan header. The BIOS only knows CPU and
chassis temperatures, so it cannot cool the GPU properly. `gpu-fan` reads the GPU
temperature and drives that header's PWM signal from a fan curve.

```
nvidia-smi -l ──°C──▶ gpu-fan daemon ──duty %──▶ /sys/class/hwmon/hwmonN/pwmX ──▶ Super I/O chip ──▶ fan header ──▶ shroud fan
                       profile curve              (it87, nct6775, ...)                   ▲
                       failsafe logic ◀──────────────── RPM (fanX_input) ────────────────┘
```

- Profiles: `silent` (fan stops when cool), `normal`, `performance`, or your own curve
- Fails safe: any error drives the fan to 100% (details below)
- Light: one long-running `nvidia-smi` process, no per-tick process spawning,
  constant memory (measurements below)
- `gpu-fan status` for a live view (`watch -n1 gpu-fan status`)
- `gpu-fan selftest` checks temperature reading and fan control end to end
- Pluggable GPU backends (NVIDIA today; AMD/Intel are easy to add)
- Plain bash, no dependencies beyond coreutils/procps and your GPU's tools

> **Use at your own risk.** This software controls cooling of expensive hardware.
> Run `gpu-fan selftest`, watch temperatures under load, and set a sane BIOS
> fan setting for the header as a fallback (see [Safety](#safety)).

## Requirements

- Linux with systemd, bash ≥ 5
- A motherboard sensor driver that exposes PWM control in `/sys/class/hwmon`
  (`it87`, `nct6775`, ...). Check with `gpu-fan list`.
- GPU tools for the backend: `nvidia-smi` (NVIDIA proprietary driver)

### Gigabyte / ITE boards (IT8686E, IT8689E, ...)

The in-kernel `it87` driver does not know newer ITE chips, so `modprobe it87`
fails with `No such device`. Use the maintained out-of-tree driver
([frankcrawford/it87](https://github.com/frankcrawford/it87)):

```sh
# Arch / Manjaro
yay -S it87-dkms-git
sudo modprobe it87 ignore_resource_conflict=1
```

`ignore_resource_conflict=1` is needed because the BIOS/ACPI claims the chip's
I/O ports. `install.sh --it87` makes the driver load at boot with that option.

## Install

```sh
git clone https://github.com/devquasar-ai/dq-gpu-fan-control
cd dq-gpu-fan-control

# 1. find your fan header
./gpu-fan list                    # PWM chips/channels and current RPM
sudo ./gpu-fan identify           # pulses each channel to 100% for 6s - watch which fan reacts
sudo ./gpu-fan identify 2         # runs only pwm2 at 100% for 60s

# 2. install (example: NVIDIA GPU, IT8689E chip, header pwm2)
sudo ./install.sh --gpu nvidia --pwm it8689:2 --profile normal --it87

# 3. verify
sudo gpu-fan selftest
watch -n1 gpu-fan status
```

The installer puts `gpu-fan` in `/usr/local/bin`, backends and profiles in
`/usr/local/lib/gpu-fan`, the config in `/etc/gpu-fan/gpu-fan.conf`, and enables
`gpu-fan.service`. Re-running it updates the program and keeps your config.

## Usage

```
gpu-fan status                     daemon state, profile, GPU temp, fan %, RPM
gpu-fan profile                    list profiles (* = active)
gpu-fan profile silent             switch profile (live, no restart)
gpu-fan profile --custom FILE      validate, install and activate a custom profile
gpu-fan profile --show [NAME]      print a profile's curve as a table
gpu-fan selftest                   end-to-end hardware check
gpu-fan list                       PWM controllers and GPU backends
gpu-fan identify [--chip C] [N]    find which PWM channel drives which fan
gpu-fan release                    hand the header back to BIOS automatic control
```

```
$ gpu-fan status
gpu-fan    running (pid 2817, up 3h12m)
profile    normal  [40:30 50:40 60:55 70:75 75:90 80:100]
gpu        nvidia (all)  62°C
fan        it8689 pwm2  58% (148/255, manual)  1840 RPM
mode       curve   (updated 1s ago)
```

`mode` is one of `curve`, `kick` (spinning up from stop), `stopped` (zero-RPM),
`critical` (≥ `CRIT_TEMP`), `failsafe` (no valid temperature) or `stalled`.

Logs: `journalctl -u gpu-fan -f` (one line per significant change).

## Profiles

| GPU °C      | 30 | 40 | 50 | 60 | 70 | 75 | 80  | 85+ |
|-------------|----|----|----|----|----|----|-----|-----|
| silent      | 0  | 0* | 29 | 42 | 64 | 80 | 95  | 100 |
| normal      | 30 | 30 | 40 | 55 | 75 | 90 | 100 | 100 |
| performance | 45 | 50 | 60 | 75 | 90 | 100| 100 | 100 |

\* `silent` stops the fan below 40°C and restarts it at 46°C (hysteresis), with
a short 60% kick to overcome inertia. Not every fan stops at 0% PWM - `selftest`
tells you.

The fan speeds up immediately and slows down gently (`STEP_DOWN` % per update).
Regardless of the profile, the fan runs at 100% at/above `CRIT_TEMP` (default 85°C).

### Custom profiles

Copy [`profiles/custom.example`](profiles/custom.example), edit, then:

```sh
sudo gpu-fan profile --custom my-curve.conf        # installs as profile "my-curve" and activates it
gpu-fan profile --show my-curve
```

Profile and config files are **parsed, never executed**: unknown keys and
out-of-range values are rejected, and an invalid file is never activated
(a running daemon keeps its current settings).

## Configuration

`/etc/gpu-fan/gpu-fan.conf` (see [`gpu-fan.conf.example`](gpu-fan.conf.example)):

| key | default | |
|---|---|---|
| `GPU_BACKEND` | `nvidia` | temperature source (`/usr/local/lib/gpu-fan/gpu/<name>.sh`) |
| `GPU_INDEX` | `all` | `all` = hottest GPU wins, or `0`, `0,2`, ... |
| `PWM_CHIP` | | hwmon chip name, e.g. `it8689`, `nct6798` (`gpu-fan list`) |
| `PWM_CHANNEL` | | PWM channel number |
| `FAN_CHANNEL` | = `PWM_CHANNEL` | tachometer channel; `0` = no RPM signal |
| `PROFILE` | `normal` | active profile |
| `INTERVAL` | `2` | seconds between updates |
| `FAILSAFE_PCT` | `100` | fan % on errors, exit and stall (50-100) |
| `CRIT_TEMP` | `85` | fan forced to 100% at/above this °C |
| `STALL_DETECT` | `1` | latch to failsafe if the fan reports 0 RPM while it should spin |

Apply changes: `sudo systemctl reload gpu-fan`.

## Safety

The goal: **no single failure leaves the fan slow while the GPU heats up.**

| failure | what happens |
|---|---|
| invalid / missing temperature reading | fan → `FAILSAFE_PCT` |
| temperature reader hangs (e.g. `nvidia-smi` stuck) | read timeout (3 × interval + 5 s) → failsafe, reader restarted |
| temperature reader exits | failsafe, reader restarted |
| GPU at/above `CRIT_TEMP` | 100% whatever the profile |
| fan stalls (0 RPM while commanded to spin) | latched to failsafe until reload, error logged |
| BIOS/driver takes the header back to auto | manual mode re-asserted every update |
| daemon exits or is stopped | exit handler sets failsafe |
| daemon killed (SIGKILL, OOM) | systemd `ExecStopPost=gpu-fan failsafe` sets failsafe |
| daemon hangs | systemd watchdog (30 s) kills it → `ExecStopPost` → restart |
| daemon keeps crashing | `Restart=always`, no start limit; failsafe applied between attempts |
| broken config file | daemon refuses to start → failsafe applied by `ExecStopPost`, which reads the config leniently |
| before the service starts (boot) / service uninstalled | **BIOS setting for the header applies** - set it to a high fixed speed or a sane curve |
| whole OS freezes | the chip keeps the last duty cycle - nothing in software can help; the GPU's own thermal slowdown/shutdown is the last line of defence |

## Resource usage

The control loop uses only bash builtins (no process is spawned per update). The
temperature comes from one long-running `nvidia-smi -l` process. Logging happens
only on significant changes (mode change, ≥5% fan or ≥5°C temperature change).

Measured on the reference machine over 5 minutes at a 1-second interval: see
[Measurements](#measurements). systemd caps the service at `MemoryMax=128M`,
`CPUQuota=10%`, `TasksMax=16`; if it ever exceeded them it would be killed,
the fan set to failsafe and the daemon restarted.

### Measurements

5 minutes, `INTERVAL=1` (twice the default rate), NVIDIA backend, 1 GPU:

| | start | after 5 min |
|---|---|---|
| processes | 4 (bash ×2, nvidia-smi, awk) | 4 |
| RSS, all processes | 47 124 kB | 47 140 kB |
| CPU time, all processes | - | 0.25 s total ≈ **0.08 %** of one core |

Most of the RSS is `nvidia-smi` and shared libraries. The process count stays
constant (no per-tick forks). Over this short run memory changed by 16 kB,
which is noise rather than evidence of a leak; the systemd `MemoryMax` cap is
the backstop for longer runs.

## Adding a GPU backend

A backend is a bash file in `gpu/` defining two functions
(see [`gpu/nvidia.sh`](gpu/nvidia.sh)):

```bash
gpu_temp_once INDEX              # print one integer: max °C of the selected GPUs; non-zero exit on failure
gpu_temp_stream INTERVAL INDEX   # forever: print one line per INTERVAL - integer °C or "ERR"; flush each line
```

`gpu_temp_stream` should be a single long-running process tree (no new process
per sample). For sysfs-based GPUs (amdgpu: `/sys/class/drm/card*/device/hwmon/hwmon*/temp*_input`)
a `while read ...; sleep` loop with bash builtins is fine.
Then: `sudo ./install.sh --gpu <name>`.

## Development

```sh
tests/run.sh          # 40+ tests: config validation, fan logic, daemon end-to-end
                      # (fake hwmon + fake GPU backend - no root, no hardware)
./gpu-fan simulate silent <<< $'35\n46\n46\n46\n39'    # feed temperatures, see decisions
```

## Uninstall

```sh
sudo ./uninstall.sh            # keeps /etc/gpu-fan
sudo ./uninstall.sh --purge    # removes config and it87 boot settings too
```

The fan header is handed back to BIOS automatic control.

## Using an AI agent to install

[`AGENTS.md`](AGENTS.md) is written for AI coding agents (Claude Code, Codex,
Cursor, ...). It covers prerequisite checks, choosing the fan driver for your
board's chip, distro-specific packages, finding the right fan header, and
troubleshooting. Point your agent at this repository and ask it to install
gpu-fan for your GPU.

## Contributing

Hardware and distro reports, and support for other fan controllers (IPMI/BMC,
USB controllers, ...), are especially wanted. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Public domain - [The Unlicense](LICENSE). Do whatever you want with it.

---
Made by [DevQuasar](https://github.com/devquasar-ai).
