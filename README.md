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

## A/B test: daemon vs. stock firmware

To be sure the daemon was doing the work (and not, say, a cooler ambient), both
configs were measured back-to-back on the same box under an **identical** sustained
load: two concurrent LLM inference streams (a 35B MoE model on the iGPU via
llama.cpp), sampled every ~10 s from `amdgpu`/`k10temp` and the AMD `gpu_metrics`
throttle-residency counters. The *only* variable was whether the daemon or the
firmware controlled the fan.

| | 🟢 **Daemon** | 🔴 **Stock firmware auto** |
|---|---|---|
| Fan RPM under load | **~4200 rpm** | **~1830 rpm — flat the whole run** |
| Peak GPU temp | **78.5 °C** (stable plateau) | **99.2 °C** (test aborted; still climbing) |
| Temp behaviour | levels off at 74–78 °C | runs away: 39 → 99 °C, no plateau |
| GPU clock | 2820 MHz, held at max | 2820 → **collapsing** (2662 MHz and falling) |
| Thermal throttling (`thm_core`) | **none (+0)** | **+30,819 and accelerating** |
| Power-cap throttling (`pwr_spl`) | active | active |

**The stock firmware never ramps the fan.** It held ~1830 rpm from 60 °C all the
way to 99 °C — essentially unresponsive to load. The daemon pushes ~4200 rpm
(≈2.3× the airflow), which is the entire difference.

Throttle onset on the firmware run, tick by tick:

- **up to ~88 °C:** only `pwr_spl` (the power cap — normal, present in *both* configs).
- **~94 °C:** `thm_core` (thermal) appears — thermal throttling begins.
- **95–99 °C:** `thm_core` explodes (+2056 → +4759 → +6670 → +8063 per tick) and the
  clock follows it down: 2818 → 2778 → 2662 MHz and still dropping when the run was
  aborted at 99 °C. Left running, that is the road back to the ~1500 MHz collapse.

Note the distinction the data makes clear: **both** configs hit the *power* cap
(`pwr_spl`) — that is the chip working at its designed envelope and is fine. The
daemon's win is purely *thermal*: it keeps the die ~20 °C cooler, so the *thermal*
throttle never triggers and clocks stay pinned at maximum. (The throttle reasons
`thm_core`/`pwr_spl` are read straight from the AMD `gpu_metrics` residency counters.)

## Root cause: the firmware can't see the GPU heat

Why doesn't the stock firmware just ramp the fan? It was traced through three
layers on the Bosgame M5:

1. **Fan control is 100% EC-internal.** The ACPI DSDT has **zero thermal zones** —
   the OS has no fan policy at all, only get/set methods. The entire curve lives in
   the EC firmware.
2. **The EC's CPU sensor is accurate.** Logging the EC's own temperature registers
   against the real die temperature under load shows `CPUT` (EC RAM `0x70`) tracks
   the die within ~1 °C. So "the sensor lags the die" is *not* the problem.
3. **The GPU-temperature channel is dead.** `GPUT` (EC RAM `0x71`) reads **`0` the
   entire time**, even under full iGPU load with the die at 73 °C:

   | die (gfx) | `CPUT` (0x70) | `GPUT` (0x71) |
   |-----------|---------------|---------------|
   | 41 °C | 42 | **0** |
   | 62 °C | 58 | **0** |
   | 73 °C | 72 | **0** |

So the fan isn't weak (it does 4200 rpm on command) and the sensor isn't lagging
(`CPUT` is accurate) — the EC's fan curve simply **never acts on the temperature
that's rising**, because it is keyed to a `GPUT` channel that is stuck at zero and/or
has absurdly high `CPUT` trip points. GPU-compute load is **thermally invisible** to
the stock fan controller.

That is exactly why these boxes cook specifically under **local LLM inference**: it
is a pure-iGPU compute load, and the one channel that would spin the fan up is
broken. This daemon sidesteps the whole thing by driving the fan off the real die
temperature directly.

## How it works

The fan registers were reverse-engineered from the board's own **ACPI DSDT** — its
`OperationRegion` / `Field` map is effectively free documentation of the EC layout:

| Field | Offset | Meaning |
|-------|--------|---------|
| `FAN1` | `0x33` | write `0x80 \| duty` → **manual** mode, `duty` = 0–100 %. `0x00` = firmware auto |
| `FAN2` | `0x34` | second fan, same encoding |
| tach   | `0x35`–`0x38` | fan RPM (read-only; tears on rapid access) |

The tach encoding is easy to get wrong: the firmware packs fan1 as
`(byte@0x35 << 8) | byte@0x36` — the byte at the *lower* offset is the *high*
byte. The reads also **tear** (the EC updates the two bytes non-atomically), so
the daemon reads twice ~20 ms apart, accepts a value only if both reads agree and
are plausible, and otherwise holds the last-known-good — giving a clean,
continuous series instead of dropped or spiking samples.

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

## Prometheus metrics (optional)

Export is **off by default**. To enable it, point `PROM_FILE` at a file inside your
[node_exporter](https://github.com/prometheus/node_exporter) **textfile-collector**
directory and restart the service:

```python
PROM_FILE = "/var/lib/prometheus/node-exporter/strix-halo-fan.prom"
```

node_exporter (run with `--collector.textfile.directory=/var/lib/prometheus/node-exporter`)
then serves these on its **own** `/metrics` — no extra port, no extra exporter, no
scrape config beyond the node_exporter job you already have:

| Metric | Labels | |
|--------|--------|--|
| `strixhalo_fan_duty_percent` | `fan="1\|2"` | commanded duty % |
| `strixhalo_fan_rpm`          | `fan="1\|2"` | measured RPM (de-teared, see above) |
| `strixhalo_temp_celsius`     | `sensor="amdgpu\|k10temp"` | the temps driving the curve |

The daemon writes the file atomically (temp + `rename`), so node_exporter never
reads a half-written file. Export runs inside its own error guard — a telemetry
failure can never interrupt fan control.

**`--monitor` mode:** run `strix-halo-fand --monitor` to leave the fan on the
firmware's own curve while still exporting metrics. It never drives the fan — it
only observes. This is how the [A/B test](#ab-test-daemon-vs-stock-firmware) above
was measured: stop the normal service, run `--monitor` so Prometheus keeps
scraping, and you can watch the stock firmware let the chip cook in real time.

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

## Related / prior art

The Bosgame M5 is a rebrand of the **Sixunited AXB35-02** board (shared with the
GMKtec EVO-X2, FEVM FA-EX9, and others), all using the **ITE IT5570E** EC — so work
on any of them applies here.

- [cmetz/ec-su_axb35-linux](https://github.com/cmetz/ec-su_axb35-linux) — a proper
  **hwmon kernel driver** for this EC (fan1/2/3 + auto/fixed/curve modes). If you
  want a fully-integrated `hwmon` device, use this. This project is a deliberately
  simpler, dependency-free **userspace** alternative: one file, easy to read and
  adapt, no module build.
- [deseven's Strix Halo wiki](https://strixhalo.wiki/Hardware/Boards/Sixunited_AXB35) —
  EC register documentation and downloadable **BIOS + standalone EC firmware images**
  (EC v1.04–1.10). EC 1.04 introduced manual fan control (the `0x80|duty` override
  used here); 1.10 added custom fan curves.
- [RyzenAdj](https://github.com/FlyGoat/RyzenAdj) — CPU undervolt / power-limit
  tuning (the `--set-coall` curve-optimiser pairs perfectly with this for Strix
  Halo thermals). Note: iGPU undervolt (`--set-cogfx`) is **not** supported on
  Strix Halo, and amdgpu OverDrive exposes only SCLK frequency, no voltage.

## License

MIT — see [LICENSE](LICENSE).
