# WattsUp

[中文](README.md)

A macOS menu bar app that draws Sankey (flow) diagrams of **where your Mac's power goes** and **what is holding its memory**. Designed for desktop Apple-silicon Macs and developed on a Mac mini (M6) running macOS 27. The interface is in Chinese.

<img src="docs/screenshot.png" width="420" alt="WattsUp panel: memory and power flows">

**Download**: get the zip from [Releases](https://github.com/Mikey-Cai/WattsUp/releases/latest), unzip it and drag WattsUp.app into Applications. The app is not notarized, so macOS blocks the first launch; allow it under System Settings → Privacy & Security → Open Anyway. Requires an Apple-silicon Mac and macOS 14+. The download has no desktop widget.

- **Memory**: five streams (app memory, wired, compressed, file cache, free), counted the same way as Activity Monitor, with a headline "used / total · about N still available". Hover "physical memory", "app memory" or "compressed" to list the ten heaviest processes; you can move the pointer onto the list to read it.
- **Memory pressure**: the memory card turns faintly yellow on warning and red on critical. Swap shows only the amount used, with a note that under normal pressure it is mostly pages swapped out earlier.
- **Memory read/write speed**: the combined DRAM bandwidth of all agents, estimated from the memory controller's bandwidth histogram (IOReport · PMP). Against a memcpy load on M6 it was within about 10 %; the top bucket is 128 GB/s, so anything above shows as "128 GB/s or more". The row is hidden on Macs that do not expose it.
- **Power**: the whole-system reading plus the parts that can actually be read. **Anything unreadable is not shown and never drawn as 0 W**; "other" is the total minus the parts shown.
- **Panel**: hangs under the menu bar icon and can be resized; pin it to keep it in place, on top, anywhere on screen. Drag either card to reorder them. Theme color, flow direction (total on the left or right) and refresh interval are adjustable.
- **Desktop widget** (needs your own signing, see below): small shows total power and memory; medium adds CPU, GPU and swap.
- System frameworks only. **No network access**, no data collection.

## Where the power numbers come from

Measured on M6 + macOS 27:

| Part | Source | Notes |
|---|---|---|
| Total | AppleSMC `PSTR` (system power sensor) | Not checked against a wall-plug meter |
| GPU | IOReport "GPU Energy" energy delta ÷ time | Cross-checked against `powermetrics`; same magnitude |
| CPU (estimate) | AppleSMC `PP0b` | Follows CPU load (about 2.5 W idle, about +10 W at full load) and does not rise under a GPU-only load, so it does not double count with GPU. Apple does not document which circuits it covers, hence "estimate". CPU busy % is shown under it |
| Other | Total − the parts above | Memory, storage, interface chips, power conversion losses and measurement error |

The Neural Engine (ANE) and DRAM have no usable power counters on this generation, and `powermetrics` cannot read them either, so they are not shown. Other tools have reported the same on M5 with macOS 27.

Sensors have three failure states: never read on this Mac (hidden), read before but failed this time ("读取失败", read failed), or frozen at the same value for a while ("数据未更新", not updating; kept out of the diagram). If the parts ever add up to more than the total in one frame, the less reliable CPU estimate is dropped first; readings are never rescaled into a split that merely looks right.

The memory accounting is derived in [docs/memory-methodology.md](docs/memory-methodology.md) (Chinese).

## Build

Requires macOS 14+ and Xcode (command line tools). No third-party dependencies.

```sh
git clone https://github.com/Mikey-Cai/WattsUp.git
cd WattsUp
./scripts/test.sh
./scripts/build.sh
open build/WattsUp.app
```

With nothing configured, the app is signed ad hoc and built **without the desktop widget**; everything else works.

### Getting the desktop widget

The widget shares data with the app through an App Group, which needs your own Team ID. Set these two variables in the environment or in a new `scripts/local.env` (ignored by git):

```sh
WATTSUP_SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"   # or the certificate's SHA-1
WATTSUP_TEAM_ID=ABCDE12345                                               # the certificate's OU
```

`security find-identity -v -p codesigning` lists your certificates. Then run `./scripts/build.sh` again; the App Group is `<Team ID>.io.github.mikey-cai.wattsup`.

Copy `WattsUp.app` into /Applications and open it once, then right-click the desktop → Edit Widgets and search for WattsUp. From other folders the system may not list it in the widget gallery.

Signing deliberately omits the hardened runtime (`-o runtime`). The main app is not sandboxed (reading AppleSMC and IOReport requires that) and only declares the App Group; the widget extension is sandboxed as WidgetKit requires and only reads a small JSON file in the shared container.

## Command line

```sh
WattsUp.app/Contents/MacOS/WattsUp --dump-json         # sample once and print every reading (missing field = unknown, not 0)
WattsUp.app/Contents/MacOS/WattsUp --probe             # read-only enumeration of all SMC keys
WattsUp.app/Contents/MacOS/WattsUp --processes         # top 10 processes by memory / compressed memory
WattsUp.app/Contents/MacOS/WattsUp --measure-overhead  # CPU time spent by sampling itself
WattsUp.app/Contents/MacOS/WattsUp --widget-snapshot   # write the widget data once
WattsUp.app/Contents/MacOS/WattsUp --cross-check-gpu   # compare GPU with powermetrics (needs the optional helper below)
python3 scripts/calibrate2.py                          # staged calibration: idle, CPU, GPU, memory bandwidth, disk
```

`helper/` contains an **optional** root helper that runs `powermetrics` once when WattsUp asks, to cross-check the GPU reading. The app does not need it day to day. Install with `sudo zsh helper/install.sh`; remove with `sudo zsh helper/install.sh --uninstall`.

## Layout

```text
Sources/WattsUpCore       Pure logic: memory accounting, Sankey layout, power split, sensor state, card reordering, panel geometry, widget snapshot
Sources/CSensors          C interfaces to AppleSMC / IOReport (energy counters and state histograms)
Sources/WattsUpHardware   Sampling: power, memory, memory bandwidth, CPU busy %, per-process memory
Sources/WattsUp           Menu bar panel, SwiftUI views, hover process list, sampling schedule
Sources/WattsUpWidget     WidgetKit desktop widget (packed into an .appex by build.sh)
Tests/WattsUpCoreTests    Unit tests
```

## Caveat

AppleSMC and IOReport are not stable public interfaces; a system update can remove a reading or change what it means. WattsUp's rule is to say when it cannot read something rather than guess.

MIT licensed; see [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
