# How to tell whether a change helped

A kernel tweak without a measurement is a rumour. This is the shortest set of
numbers that can tell "better" from "different", on this phone, in about ten
minutes per batch.

Every batch is measured the same way, on the same ROM, with the same apps
installed, with the phone at the same starting battery percentage. Two runs is a
coincidence; three is a measurement.

## Baseline first

Before flashing anything, capture the current kernel's numbers, so there is
something to compare against:

```bash
adb shell uname -r                              # which kernel these numbers belong to
adb shell dumpsys batterystats --reset          # start counting from now
```

Then use the phone normally for an hour, and save:

```bash
adb shell dumpsys batterystats > baseline-batterystats.txt
adb shell cat /proc/pressure/memory
adb shell cat /proc/meminfo | grep -E 'MemAvailable|SwapTotal|SwapFree'
adb shell dumpsys cpuinfo > baseline-cpuinfo.txt
```

## The four things worth measuring

### 1. Idle drain (battery, the honest one)

```bash
adb shell dumpsys batterystats --reset
# screen off, unplugged, one hour, nothing running
adb shell dumpsys batterystats | grep -A 3 "Discharge"
```

What matters: **% per hour at idle**. If a tuning change costs 0.3 %/h, the
phone is worse in the pocket no matter what a benchmark says.

### 2. Screen-on drain under a fixed load

Same brightness, same video, 30 minutes, aeroplane mode on so radios are not a
variable. Record the percentage drop. This is where zram and scheduler changes
show up.

### 3. App cold starts (performance you can feel)

```bash
adb shell am start -W -n com.android.settings/.Settings
adb shell am start -W -n com.google.android.youtube/.app.honeycomb.Shell$HomeActivity
```

`TotalTime` in milliseconds. Three runs each, take the median. Cold start after
a reboot is the number that matters, because that is when memory pressure is
real.

### 4. Memory pressure and kills (what zram is for)

```bash
adb shell cat /sys/block/zram0/mm_stat    # only if zram is actually configured
adb shell cat /proc/pressure/memory
adb shell logcat -b events -d | grep -i lmkd | tail -20
```

- `mm_stat` line 1 is original size, line 2 is compressed size: the ratio tells
  you whether the compressor setting is sane.
- `/proc/pressure/memory` `full avg10` above ~5 under load means the phone is
  thrashing.
- `lmkd` kill events should get **fewer** with zram working. If they do not,
  either init is not configuring zram (check `/sys/block/zram0` exists) or the
  size is too small.

## Reading the result

| what you see | what it means |
|---|---|
| idle %/h worse by more than 0.2 | revert, whatever the benchmark says |
| cold starts better, idle unchanged | win, keep it |
| LMK kills down, screen-on drain flat | win, keep it |
| everything within noise | the change did nothing; revert it rather than carry it |

"No change" is a valid result and the correct action is to delete the change.
A kernel that carries ten neutral tweaks is a kernel nobody can explain.

## What is not measured here

Sustained load (games, camera) and thermal behaviour, because both depend on
ambient temperature and on the vendor's thermal profile far more than on this
kernel. If a change is aimed at sustained performance, it needs a fixed
30-minute game run with the phone starting at the same temperature, and even
then the number is noisy.
