---
name: Hardware / distro report
about: Report whether gpu-fan works on your motherboard, fan chip and Linux distribution
title: "[hardware] <board> / <fan chip> / <distro>"
labels: hardware-report
---

**Result:** works / works with workarounds / does not work

**System**
- Distro + version:
- Kernel (`uname -r`):
- Board (`cat /sys/class/dmi/id/board_{vendor,name}`):
- Fan chip + driver (in-kernel / DKMS / package name):
- Kernel parameters or modprobe options needed:
- Secure Boot: on / off (if on, how the module was signed):
- GPU + driver version:
- Fan (model, 3-pin / 4-pin, has tach?):
- Header used (board label) -> sysfs channel (`pwmN` / `fanN`):

**Output**

<details><summary>gpu-fan list</summary>

```
```
</details>

<details><summary>sudo gpu-fan selftest</summary>

```
```
</details>

<details><summary>gpu-fan status</summary>

```
```
</details>

**Workarounds / notes**
