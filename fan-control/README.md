# sysmon-fand

Temperature-driven control for motherboard PWM fan headers, for when the firmware's fan curves can't see the sensor that matters. The typical case is case fans that should speed up when the GPU gets hot.

> **Read this whole page before using it.** `sysmon-fand` runs as root and writes directly to fan hardware. The wrong channel number can slow or stop a pump or a CPU fan. It has been tested on a single desktop board with a Nuvoton NCT6798 controller.

## How it behaves

- **Nothing about your hardware is assumed.** It refuses to start until the config names a chip and its channels, and it rejects unknown or repeated settings, so a typo fails loudly instead of being ignored.
- **Protected channels are never written.** A config that tries to control a channel listed in `protect` is rejected.
- **It checks it can give control back first.** Before taking over a channel, it writes the channel's current mode back to it, which changes nothing. If the driver rejects that, the channel could not be returned to automatic control until reboot, so the daemon refuses to start unless you set `allow_irreversible = yes`.
- **On exit** (stop, crash, Ctrl+C), each channel is handed back to the firmware's automatic mode. Where that isn't possible, it is pinned at `failsafe_percent`, which the chip holds with no daemon running.
- **If a temperature can't be read,** the channel goes straight to `failsafe_percent`.
- **A sleeping NVIDIA GPU is not woken** to read its temperature. It's idle, so it simply doesn't count.
- **Speed rises immediately and eases down** by `falloff_percent` per interval, so fans don't hunt.
- **`max_percent` is a hard ceiling** on every path, including the fail-safe.

One case it can't handle: if the process is killed with `SIGKILL`, no exit handling runs, and the fans hold their last speed until systemd restarts the daemon about two seconds later.

## Requirements

- A hwmon driver exposing `pwmN` and `pwmN_enable` for your fan headers, such as `nct6775` for Nuvoton chips or `it87` for ITE chips. To load it at boot: `echo nct6775 | sudo tee /etc/modules-load.d/nct6775.conf`
- systemd and bash 4.4 or newer.
- `nvidia-smi` for NVIDIA GPU temperatures. AMD GPUs are read from sysfs.

## 1. Identify your hardware

```sh
./sysmon-fand-detect
```

It lists each fan controller with its fans (RPM) and PWM channels (duty and mode), and writes nothing. Two things it can't tell you:

- **Which pwm drives which fan.** `pwmN` often drives `fanN`, but not always, and one header can feed a hub. The tool's output explains how to find out safely through your firmware settings.
- **Which header is a pump.** Check your cabling. Pumps usually belong in `protect`.

## 2. Install

```sh
sudo ./install.sh
```

This installs `/usr/local/bin/sysmon-fand`, `/usr/local/bin/sysmon-fand-detect` and a systemd service, and creates `/etc/sysmon-fand/fand.conf` from the example if you don't have one yet. It doesn't enable or start anything.

## 3. Configure

Edit `/etc/sysmon-fand/fand.conf`, for example with `sudoedit`. The file is owned by root on purpose: a root process reads it and acts on hardware. It is parsed as plain `key = value` lines and never run as a script.

| Setting | Default | |
|---|---|---|
| `chip` | required | hwmon name of the fan controller, from `sysmon-fand-detect` |
| `interval` | `3` | seconds between adjustments (1 to 60) |
| `gpu` | `auto` | `auto`, `nvidia`, `amd` or `none` |
| `protect` | none | comma-separated channels that are never written |
| `falloff_percent` | `2` | largest drop in speed per interval |
| `allow_irreversible` | `no` | see [How it behaves](#how-it-behaves) |
| `channel.N.label` | `pwmN` | name used in logs |
| `channel.N.min_percent` | required | never go below this |
| `channel.N.max_percent` | required | never go above this |
| `channel.N.failsafe_percent` | `max_percent` | held on exit and when a temperature can't be read |
| `channel.N.cpu_curve` | | `temp:percent` pairs, e.g. `50:20 70:50 85:100` |
| `channel.N.gpu_curve` | | the same, for the GPU |

`N` is the `pwmN` number. Each channel needs at least one curve. Between points the speed is interpolated. Below the first point it uses the first point's percent, and past the last point it runs at `max_percent`. With both curves, the faster one wins.

## 4. Check, watch, enable

```sh
sysmon-fand --check       # validate the config against your hardware and sensors
sysmon-fand --dry-run     # print what it would write, without writing (Ctrl+C to stop)
sudo systemctl enable --now sysmon-fand
journalctl -u sysmon-fand -f
```

The service runs `--check` before every start, so a broken config never takes over a fan.

## Uninstall

```sh
sudo ./uninstall.sh
```

This stops the service (handing fans back, as above), removes the program and the service, and keeps `/etc/sysmon-fand/`. After uninstalling, a reboot returns every fan header to your firmware's own control.
