# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Aider, ...) helping a
user **install**, **troubleshoot** or **develop** `dq-gpu-fan-control`.

The project installs one bash program, `gpu-fan`, and a systemd service,
`gpu-fan.service`. The service reads GPU temperature and drives one motherboard
fan header's PWM signal through the Linux hwmon sysfs interface
(`/sys/class/hwmon/hwmonN/pwmX`). Read `README.md` for the user-facing overview.

## Safety rules

This software controls cooling of expensive hardware. Follow these rules when you
act on a user's machine:

1. **Ask before writing to any `pwm*` file**, running `gpu-fan identify`,
   `gpu-fan selftest`, or `install.sh`. These change fan speeds, and `selftest`
   briefly stops the fan.
2. **Never set `FAILSAFE_PCT` below 100 or `CRIT_TEMP` above the GPU's max
   operating temperature** unless the user explicitly asks. Find that temperature with
   `nvidia-smi -q -d TEMPERATURE` ("GPU Max Operating Temp").
3. **Don't leave a fan header in manual mode at low speed.** If you write PWM
   values by hand, restore the previous `pwmN_enable` and `pwmN` values afterwards.
   `gpu-fan identify` does this automatically.
4. **Stop the service before running `identify`** (`sudo systemctl stop gpu-fan`),
   or the daemon and the test will both write to the fan. `selftest` stops and
   restarts the service on its own.
5. Tell the user to **set a safe BIOS fan setting** for the header (high fixed
   speed or a sane curve). The BIOS controls the fan before the service starts and
   after an uninstall.
6. Don't use `acpi_enforce_resources=lax` or `ignore_resource_conflict=1` without
   telling the user. They are common and usually harmless, but they bypass a
   firmware claim on the chip's I/O ports.
7. You may need sudo. If you can't run sudo non-interactively, give the user the
   exact command to run. Keep each command on one line: long commands that wrap
   when pasted break in the shell.

## Install workflow

Run the steps in order. Don't move to the next step until the current one passes.

### 1. Check the base requirements

```sh
bash --version | head -1            # need bash >= 5.0
systemctl --version | head -1       # need systemd
command -v timeout pkill awk grep sed install   # coreutils, procps, awk
uname -r; cat /etc/os-release | head -3
```

### 2. Check the GPU temperature source

| GPU | backend | check |
|---|---|---|
| NVIDIA (proprietary or open kernel module) | `nvidia` | `nvidia-smi --query-gpu=index,name,temperature.gpu --format=csv` |
| AMD, Intel | not implemented yet | see "Adding a GPU backend" in README.md |

If `nvidia-smi` is missing, the user needs the NVIDIA driver's utilities package:
- Arch/Manjaro: `nvidia-utils`
- Debian/Ubuntu: `nvidia-utils-<version>`, matching the driver
- Fedora (RPM Fusion): `xorg-x11-drv-nvidia-cuda`

### 3. Check for a PWM fan controller

From the repo directory:

```sh
./gpu-fan list
```

If the output lists `pwmN` channels, go to step 4.

If it says **"none found"**, the motherboard's Super I/O chip has no driver loaded:

```sh
sudo sensors-detect --auto 2>/dev/null | grep -iE 'found|driver|chip'   # package: lm_sensors / lm-sensors
sudo dmesg | grep -iE 'it87|nct67|f718|resource conflict|ACPI.*conflict'
cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name
```

Then use the table below to load the right driver.

| chip (from sensors-detect) | typical boards | driver | notes |
|---|---|---|---|
| ITE IT8686E, IT8688E, IT8689E, IT8792E | Gigabyte / Aorus AM4 and AM5, recent Intel | `it87` **out-of-tree** ([frankcrawford/it87](https://github.com/frankcrawford/it87)) | the in-kernel `it87` gives `No such device`; needs `ignore_resource_conflict=1` |
| ITE IT8620E, IT8628E, IT8665E, IT8728F, ... | older Gigabyte, ASRock | `it87` (in-kernel) | try `sudo modprobe it87 ignore_resource_conflict=1` first |
| Nuvoton NCT6775 to NCT6799 | ASUS, MSI, ASRock | `nct6775` (in-kernel) | recent kernels reach some ASUS/MSI boards through WMI; older kernels may need the boot parameter `acpi_enforce_resources=lax` |
| Fintek F718xx | some ASRock, older boards | `f71882fg` (in-kernel) | |
| Dell desktops and laptops | | `dell-smm-hwmon` | PWM control is limited by the BIOS |
| server board with a BMC (Supermicro, ASRock Rack, Dell iDRAC, ...) | | **not hwmon**: fans are controlled over IPMI | not supported yet; a good contribution (see CONTRIBUTING.md) |
| laptops in general | | usually EC-controlled, no PWM in hwmon | not supported |

Installing the out-of-tree `it87` driver with DKMS:

| distro | commands |
|---|---|
| Arch / Manjaro | `yay -S it87-dkms-git` (AUR; pulls in `dkms`). Kernel headers: `linux-headers` on Arch; `linuxXYZ-headers` on Manjaro, matching `uname -r` |
| Debian / Ubuntu | `sudo apt install dkms linux-headers-$(uname -r) git`, then clone frankcrawford/it87 and follow its README's DKMS install |
| Fedora | `sudo dnf install dkms kernel-devel git`, then the same as Debian |
| openSUSE | `sudo zypper install dkms kernel-default-devel git`, then the same as Debian |

Then load the driver and check again:

```sh
sudo modprobe -r it87; sudo modprobe it87 ignore_resource_conflict=1
./gpu-fan list
```

**Secure Boot:** if Secure Boot is enabled, an unsigned DKMS module won't load
(`Key was rejected by service` / `Required key not available`). Check with
`mokutil --sb-state` or `bootctl status`. The user must either enroll a MOK key for
DKMS signing (Debian/Ubuntu/Fedora usually set this up during `dkms install`) or sign
with their own tooling, for example `sbctl`.

### 4. Identify the fan header

The PWM channel numbers in sysfs (`pwm1`, `pwm2`, ...) **don't map predictably to
the header names printed on the board** (CPU_FAN, SYS_FAN1, CHA_FAN2, ...). The
mapping differs between chips, drivers and board revisions, so always identify the
header by testing. Don't guess from the manual.

#### Before you start

- Ask the user's permission and tell them what will happen: fans will spin up to
  full speed one at a time, and it will be loud for a while.
- Ask the user to be at the machine and **watch or listen to the GPU shroud fan**.
  If the case is closed, a hand near the shroud fan's exhaust works too.
- Stop the service if it's installed: `sudo systemctl stop gpu-fan` (start it
  again afterwards). Otherwise the daemon keeps resetting the channel it controls.
- Take a baseline with `./gpu-fan list`. Note each channel's `value`
  (0-255 duty), `enable` (1 = manual, 2+ = BIOS/chip automatic) and `fanN` RPM.
  Headers with nothing plugged in usually show `0 RPM` or `-`.
- If there are several PWM chips (`gpu-fan list` shows more than one), pick one
  with `--chip NAME`. Otherwise `identify` uses the chip from the config, or the
  first chip that has PWM channels.

#### Scan all channels

```sh
sudo ./gpu-fan identify
```

For each channel in turn, it:
1. saves `pwmN` and `pwmN_enable`
2. switches the channel to manual mode and sets 100%
3. waits 6 seconds, then prints every fan's RPM
4. restores the saved values and pauses 3 seconds

A 5-channel chip takes about 45 seconds. Ctrl+C restores the current channel
before exiting. Example output:

```
chip: it8689_32020507 (/sys/class/hwmon/hwmon5)
>>> pwm1 at 100% for 6s - watch/listen which fan ramps up
    fan1_input=2310 RPM      <- rose from ~1450: pwm1 drives fan1 (CPU fan here)
    fan2_input=1080 RPM
>>> pwm2 at 100% for 6s - watch/listen which fan ramps up
    fan1_input=1460 RPM
    fan2_input=3150 RPM      <- rose from ~1080: pwm2 drives fan2 = GPU shroud fan
...
```

#### Read the results

- **The user hears or sees the shroud fan ramp up during `pwmN`:** that's the
  channel.
- **An RPM reading jumps during `pwmN`:** the matching `fanM_input` is that fan's
  tachometer. Usually M = N; if not, set `FAN_CHANNEL=M` in the config.
- **The fan ramps up but no RPM reading changes:** the fan has no tach wire (common
  with server fans on adapters, or fans powered from a splitter's secondary lead).
  Set `FAN_CHANNEL=0`. Stall detection and the selftest RPM checks will be
  disabled.
- **Nothing reacts on any channel:**
  - the fan may already be at full speed: check its baseline RPM
  - it may be a 3-pin (DC) fan on a header set to PWM mode: change the header to
    DC/voltage mode in the BIOS, or use a 4-pin PWM fan
  - it may be powered from Molex/SATA or a PSU adapter rather than the header
  - it may be on a different chip: try `--chip`
- **Several fans react on one channel:** they share the header through a splitter.
  That's fine, but all of them will follow the GPU curve.
- **The CPU fan ramps up:** harmless, since it's only 100% for 6 seconds, but
  **never install gpu-fan on the CPU fan's channel.**

#### Confirm a single channel

```sh
sudo ./gpu-fan identify 2           # pwm2 only, 100% for 60 s, then restored
sudo ./gpu-fan identify --chip nct6798 3
```

Use this to double-check before installing, or when the 6-second pulses were too
short to tell fans apart. While it runs, watch the RPM in another terminal with
`watch -n1 'cat /sys/class/hwmon/hwmon*/fan*_input'`.

#### Record the result

- **Chip:** the name as `gpu-fan list` prints it, without any `_suffix`. For
  example `it8689` from `it8689_32020507`, or `nct6798`. gpu-fan finds the chip by
  name because the `hwmonN` number can change between boots.
- **PWM channel:** goes into `--pwm <chip>:<channel>` in step 5.
- **Tachometer channel:** goes into `FAN_CHANNEL` if it differs from the PWM
  channel, or is 0 if the fan has none.

If the user wants to report their hardware, the result belongs in a hardware
report too (see CONTRIBUTING.md).

### 5. Install

```sh
sudo ./install.sh --gpu nvidia --pwm <chip>:<channel> --profile normal [--it87]
```

Use `--it87` only for ITE chips. It writes `/etc/modprobe.d/gpu-fan-it87.conf` and
`/etc/modules-load.d/gpu-fan-it87.conf`. For other chips, make the driver load at
boot yourself: `echo nct6775 | sudo tee /etc/modules-load.d/nct6775.conf`.

### 6. Verify

```sh
sudo gpu-fan selftest       # must end "selftest passed" (warnings are explained in its output)
gpu-fan status              # "running", GPU temp and RPM shown
journalctl -u gpu-fan -n 20 --no-pager
```

How to read the selftest results:
- **FAIL "0 RPM at 100%":** wrong channel, the fan isn't connected, or the tach is
  on another channel (see `FAN_CHANNEL`).
- **FAIL "fan stalls at N%":** raise `MIN_PCT` in the profile.
- **WARN "keeps spinning at 0%":** the fan can't stop. The `silent` profile will
  only slow it to its minimum, which is harmless.
- **WARN "RPM barely changes":** the header may be in DC/voltage mode. Switch it
  to PWM mode in the BIOS, or check `pwmN_mode` in sysfs if the driver exposes it.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `modprobe: ... No such device` (it87) | the chip isn't supported by the in-kernel driver; use the out-of-tree driver |
| `modprobe: ... Module it87 not found` right after an update | the kernel was upgraded but not yet rebooted; reboot |
| `gpu-fan status` shows `STALE` or `not running` | `journalctl -u gpu-fan -n 50`; `systemctl status gpu-fan` |
| `PWM chip '<x>' not found` in the log | the driver isn't loaded at boot, or the chip name changed; check with `gpu-fan list` |
| fan always at 100%, mode `failsafe` | no temperature reading: run the backend's command by hand (e.g. `nvidia-smi`) |
| mode `stalled` | the fan reported 0 RPM while it should spin; fix MIN_PCT or wiring, then `sudo systemctl reload gpu-fan` |
| speed jumps back after you write it by hand | the daemon re-asserts its value every interval; stop the service first |
| BIOS fan curve fights the daemon | expected; the daemon forces manual mode (`pwmN_enable=1`) every update |
| fan control lost after a kernel update | the DKMS module didn't build: `dkms status`, `sudo dkms autoinstall` |

## Repository layout

```
gpu-fan                 the whole program (daemon + CLI), bash
gpu/<name>.sh           GPU temperature backends (gpu_temp_once, gpu_temp_stream)
profiles/*.conf         built-in fan curves; custom.example documents every key
gpu-fan.conf.example    config template -> /etc/gpu-fan/gpu-fan.conf
systemd/gpu-fan.service unit (watchdog, ExecStopPost failsafe, resource limits, hardening)
install.sh, uninstall.sh
tests/run.sh            test suite (fake hwmon + fake GPU backend; no root, no hardware)
```

## Development rules

- Run `tests/run.sh` and `shellcheck -x -s bash gpu-fan install.sh uninstall.sh tests/run.sh gpu/*.sh`
  before every commit. CI runs both.
- **The control loop must not start a process per update.** Use bash builtins only
  (`read`, `printf`, `$(( ))`, `$EPOCHSECONDS`). Read files with `read -r v < file`,
  not `$(cat file)`. Temperature comes from one long-running reader process.
- **Config and profile files are parsed, never sourced or executed.** New keys go
  into `CONFIG_KEYS` or `PROFILE_KEYS` and need a rule in `validate()`.
- **Every new failure path must end at `FAILSAFE_PCT`.** Add a test that proves it.
- Keep fan decisions in `tick()` (pure logic). It's tested quickly through
  `gpu-fan simulate`.
- Test new behaviour in `tests/run.sh` against the fake hwmon tree
  (`GPU_FAN_HWMON_ROOT`, `GPU_FAN_CONF`, `GPU_FAN_LIB`, `GPU_FAN_STATE_DIR`).
- Contribution priorities and the hardware report format are in `CONTRIBUTING.md`.
