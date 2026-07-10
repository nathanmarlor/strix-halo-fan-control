# strix-halo-fan-control

Direct fan control for **AMD Strix Halo** (Ryzen AI Max+ 395) mini-PCs whose
firmware locks the fan curve and exposes **no** standard Linux fan control — no
`hwmon` PWM, no fan tachometer, no ACPI fan object.

Validated on the **Bosgame M5** (ITE **IT5570** Embedded Controller). The approach
generalises to other Strix Halo boxes, but the exact EC register offsets may
differ — see [Adapting to your board](#adapting-to-your-board) before running.

## Why this exists

These mini-PCs pack a 16-core CPU + 40-CU iGPU sharing a single power/thermal
budget, and ship with a **conservative fan curve baked into the Embedded
Controller**. Under sustained load — local LLM inference being the obvious one —
they thermal-throttle hard.

Measured on a Bosgame M5 running llama.cpp on the iGPU, **before**:

- GPU pinned at **97–100 °C**
- GPU clock dragged from its 2900 MHz max down to **~1500 MHz**
- the EC's stock fan curve nowhere near ramping up

And the fan is **invisible to Linux** — nothing to bind a driver to:

```
$ ls /sys/class/hwmon/*/pwm*        # nothing
$ ls /sys/class/hwmon/*/fan*_input  # nothing
```

Because the fan is owned by an ITE IT5570 EC, not a standard SuperIO sensor chip.
This daemon talks to that EC **directly** and runs an aggressive,
temperature-driven fan curve.

**After** (same box, aggressive curve + a −20 mV CPU undervolt via
[ryzenadj](https://github.com/FlyGoat/RyzenAdj)):

| | GPU temp | GPU clock | throttling |
|---|---|---|---|
| before | 97–100 °C | ~1500 MHz | heavy |
| after  | **~62 °C** | **~2900 MHz** | ~none |

Local inference throughput went from throttled to full-clock, with the fan still
having headroom to spare.

## How it works

The fan registers were reverse-engineered from the board's own **ACPI DSDT** — its
`OperationRegion` / `Field` map is effectively free documentation of the EC layout:

| Field | Offset | Meaning |
|-------|--------|---------|
| `FAN1` | `0x33` | write `0x80 \| duty` → **manual** mode, `duty` = 0–100 %. `0x00` = firmware auto |
| `FAN2` | `0x34` | second fan, same encoding |
| tach   | `0x35`–`0x38` | fan RPM (read-only; tears on rapid access) |

The daemon reads the GPU (`amdgpu`) and CPU (`k10temp`) temperatures every couple
of seconds, picks a duty from a curve, and writes **both** fans through the
kernel's `ec_sys` debug interface. Bit 7 = manual override; on this EC the firmware
does *not* fight the override, so a periodic write holds it.

## Safety

Fan control is a "don't get this wrong" area, so the daemon is built fail-safe:

- **It only ever cools *harder* than stock.** The curve never sets a low duty at a
  high temp; there is a minimum-duty floor.
- **On any error** (unreadable temp, EC write failure) **or on stop / SIGTERM**, it
  writes `0x00` and hands the fan back to the firmware's own auto curve.
- The default worst case is therefore "fan too fast", never "fan too slow".

You are still poking an Embedded Controller with `ec_sys write_support=1`. **Use at
your own risk.** The realistic failure mode is a fan stuck at 100 % (loud, but
safe) until reboot. There is no warranty; see [LICENSE](LICENSE).

## Requirements

- A Strix Halo mini-PC with an ITE-style EC (validated: Bosgame M5 / IT5570)
- Linux with the `ec_sys` module (mainline; ships with most distros)
- Python 3 (stdlib only — no dependencies)
- root (to load `ec_sys write_support=1` and write the EC)

## Install

```bash
git clone https://github.com/nathanmarlor/strix-halo-fan-control
cd strix-halo-fan-control
sudo ./install.sh
```

That installs the daemon to `/usr/local/bin/strix-halo-fand`, enables a systemd
unit that loads `ec_sys write_support=1`, and starts it.

```bash
systemctl status strix-halo-fand
journalctl -u strix-halo-fand -f      # watch it: "temp=62C -> fan=70%"
sudo systemctl stop strix-halo-fand   # reverts the fan to firmware auto
```

## Configuration

Edit the `CONFIG` block at the top of `strix-halo-fand` and restart the service.
The default curve is **max-performance** (ramps hard, 100 % by 82 °C):

```python
CURVE = [(50, 45), (60, 55), (70, 70), (78, 85), (82, 95), (999, 100)]
FLOOR = 30                 # minimum duty %
TEMP_SOURCES = ["amdgpu", "k10temp"]   # drives off the hottest
FAN2 = 0x34                # set to None for a single-fan board
```

For a quiet-at-idle box, lower the first curve points (e.g. `(50, 30)`); the daemon
still slams to 100 % under load.

## Adapting to your board

The register offsets are **specific to the Bosgame M5 / IT5570**. On a different
Strix Halo box, confirm them before trusting the defaults:

**1. Read the EC map from your own DSDT** (it documents the field layout):

```bash
sudo apt install acpica-tools        # or your distro's equivalent
sudo acpidump -n DSDT -o dsdt.bin
acpixtract -a dsdt.bin && iasl -d dsdt.dat
grep -niE "OperationRegion|FAN|Field \(" dsdt.dsl | less   # find the fan fields + offsets
```

Look for the `OperationRegion` covering the EC and the `FAN1`/`FAN2`/tach fields;
note their byte offsets and put them in the `CONFIG` block.

**2. Verify reads** — dump the EC and watch the tach change under load:

```bash
sudo modprobe ec_sys
sudo xxd /sys/kernel/debug/ec/ec0/io   # inspect bytes; load the GPU and watch RPM offsets move
```

**3. Verify writes — safely.** Test at **100 %** first (max cooling, cannot
overheat), confirm the fan audibly ramps, then revert:

```bash
sudo modprobe -r ec_sys; sudo modprobe ec_sys write_support=1
printf '\xe4' | sudo dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=$((0x33)) count=1 conv=notrunc  # 0x80|100
printf '\x00' | sudo dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=$((0x33)) count=1 conv=notrunc  # back to auto
```

**Never** test a low duty at high temp.

## Related

- [RyzenAdj](https://github.com/FlyGoat/RyzenAdj) — CPU undervolt / power-limit
  tuning (the `--set-coall` curve-optimiser pairs perfectly with this for Strix
  Halo thermals). Note: iGPU undervolt (`--set-cogfx`) is **not** supported on
  Strix Halo, and amdgpu OverDrive exposes only SCLK frequency, no voltage.

## License

MIT — see [LICENSE](LICENSE).
