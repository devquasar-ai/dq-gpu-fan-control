# Contributing

Contributions are welcome. The project is public domain ([Unlicense](LICENSE)), so
by contributing you agree your work is released under the same terms.

Two kinds of contribution are especially wanted:

1. **Hardware and distro reports**: does it work on your motherboard, fan chip and
   Linux distribution?
2. **Support for other fan controllers**: drive fans through something other than
   a motherboard hwmon PWM header.

New GPU temperature backends (AMD, Intel) are also welcome; see "Adding a GPU
backend" in the README.

## 1. Test on other distros and motherboards

So far the project is verified on **one** setup:

| distro | kernel | board | fan chip / driver | GPU | result |
|---|---|---|---|---|---|
| Manjaro | 6.12 | Gigabyte B450M DS3H WIFI-CF | ITE IT8689E / it87 (out-of-tree, DKMS) | NVIDIA CMP 170HX | works, incl. silent zero-RPM |

Every additional row helps. Reports of failures are as valuable as successes.

**How to test:**

```sh
git clone https://github.com/devquasar-ai/dq-gpu-fan-control && cd dq-gpu-fan-control
tests/run.sh                         # no root, no hardware: should pass everywhere
./gpu-fan list                       # does your fan chip show up with pwm channels?
sudo ./gpu-fan identify              # which channel is your GPU fan? (see AGENTS.md, step 4)
sudo ./install.sh --gpu nvidia --pwm <chip>:<channel> [--it87]
sudo gpu-fan selftest
```

Then [open a hardware report issue](../../issues/new?template=hardware-report.md)
with:
- distro and version, kernel (`uname -r`), bash version
- board (`cat /sys/class/dmi/id/board_{vendor,name}`)
- fan chip and driver, and how you got the driver working (package, DKMS, kernel
  parameters, Secure Boot signing)
- GPU and driver version
- the output of `gpu-fan list`, `sudo gpu-fan selftest` and `gpu-fan status`
- anything you had to change or work around

Pull requests that improve the distro- and chip-specific instructions in
`AGENTS.md` are very welcome: package names, driver quirks, BIOS settings.
That file is what users' AI agents read when they help with installs, so
accurate details there help everyone.

## 2. Add support for other fan controllers

Today the fan side talks directly to the Linux **hwmon sysfs PWM interface**
(`/sys/class/hwmon/hwmonN/pwmX`, `pwmX_enable`, `fanX_input`). Any chip with a
hwmon driver that exposes PWM already works without code changes: it87, nct6775,
f71882fg, dell-smm-hwmon and others.

Wanted: controllers that are **not** plain hwmon PWM, for example:

- **IPMI / BMC fan control** on server boards (Supermicro, ASRock Rack, Dell iDRAC,
  HPE iLO) via `ipmitool raw` commands. This is the natural home for server GPUs.
- **USB fan controllers and hubs** (e.g. via `liquidctl`: Corsair Commander,
  NZXT Smart Device / RGB & Fan Controller, Aquacomputer, ...)
- **Fan controllers with hwmon drivers but a different interface**, e.g. no
  `pwmX_enable`, or speed set as target RPM (`fanX_target`)
- **Several headers at once**, e.g. two shroud fans on two headers

### Design to follow

Fan-side code is currently a handful of functions in `gpu-fan`: `find_hwmon`,
`set_pct`, `read_rpm` and `cmd_release`. The plan is to move them into pluggable
fan backends, mirroring the GPU backends:

```
fan/<name>.sh   defines:
  fan_open        locate the device from config (PWM_CHIP, PWM_CHANNEL, or new keys); non-zero on failure
  fan_set_pct N   set duty 0-100 and force manual control; non-zero on failure
  fan_read_rpm    set global RPM (integer) or "" if the fan has no tachometer
  fan_release     hand control back to firmware / automatic mode
```

The first fan-backend PR can do this refactor, with `hwmon` as the first backend,
plus the new controller. Requirements:

- **No new process per update for `fan_set_pct` and `fan_read_rpm` when
  possible.** If the controller needs an external tool (`ipmitool`, `liquidctl`),
  only call it when the duty actually changes, and read RPM no more often than
  needed. Document the resulting CPU cost.
- **Fail safe:** `fan_set_pct` must report errors, and the daemon must still end
  up at `FAILSAFE_PCT` on every failure path, including `ExecStopPost`. For BMCs,
  "release to BMC automatic mode" is often the safest failsafe; document what
  your backend does.
- **Config stays declarative:** new keys go through `validate()` and nothing in
  a config file is ever executed.
- **Tests:** extend `tests/run.sh` with a fake device (a fake `ipmitool` /
  `liquidctl` script on `PATH`, or a fake sysfs tree), so CI can run without
  hardware.

Open an issue first describing the controller and how it is commanded. Most of
the design questions are about safety and update rate, and they're easier to
settle before the code is written.

## Pull request checklist

- [ ] `tests/run.sh` passes
- [ ] `shellcheck -x -s bash gpu-fan install.sh uninstall.sh tests/run.sh gpu/*.sh` is clean
- [ ] new behaviour has tests (fake hwmon / fake backend)
- [ ] every new failure path ends at `FAILSAFE_PCT`
- [ ] no new process per update in the control loop
- [ ] README / AGENTS.md updated if install steps or behaviour changed
- [ ] tested on real hardware if it touches hardware: say which in the PR

See `AGENTS.md` ("Development rules") for code conventions.
