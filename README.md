# fpga-devbox

A small set of scripts for provisioning an **OrbStack-based FPGA development VM** on macOS and using it like a persistent Linux desktop for **Vivado**, **Vitis Unified 2025.2**, **Verilator**, and **Icarus Verilog**. The workflow uses an OrbStack Ubuntu machine plus **XRDP + XFCE** so the environment behaves more like a native Linux workstation than a collection of forwarded X11 windows.

## What this repo does

This repository automates three parts of the workflow:

- Host-side setup on macOS, including OrbStack and an RDP client (Windows App or Microsoft Remote Desktop) if needed.
- Guest-side setup inside the OrbStack Linux machine, including XRDP, XFCE, Vitis Unified, Vivado dependencies, and the OSS CAD Suite (Verilator, Icarus Verilog, Yosys, nextpnr, and more).
- Daily startup through a launcher script that can open the Linux desktop or launch Vivado/Vitis in the machine session.

## Repository layout

```text
.
├── config/
│   └── vitis_unified_2025.2.install_config
├── setup_fpga_devbox_host.sh
├── setup_fpga_devbox_machine.sh
├── fpga_devbox.sh
└── README.md
```

## Requirements

Before using the scripts, make sure the following are already true:

- macOS host with **Homebrew** installed.
- **OrbStack** can be installed on the host, or will be installed by the host setup script.
- On **Apple Silicon**, OrbStack creates an **amd64** Linux machine backed by **Rosetta** so the x86_64 Vivado/Vitis toolchain can run.
- The **AMD/Xilinx Vitis Unified 2025.2 Linux installer** has already been downloaded. Supported packages include:
  - `Xilinx_Unified_2025.2_*.bin` or `*.tar.gz`
  - `FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_*.bin` (web-installer client; downloads payloads during install)
- For **`.bin` / SDI** installers: an **AMD account**, **internet access** in the VM, and a one-time **`xsetup -b AuthTokenGen`** step (the guest script handles this when possible).
- For **full offline `.tar.gz`** installers: no auth token is required (`SKIP_AUTH_TOKEN_GEN=1` is automatic).
- Enough free disk space is available for Vitis/Vivado and device support packages.

## Scripts

### `setup_fpga_devbox_host.sh`

Runs on the macOS host.

Responsibilities:
- Installs OrbStack if missing.
- Installs Windows App or Microsoft Remote Desktop if missing.
- Creates an OrbStack Ubuntu machine named `xilinx-dev` by default.
- On Apple Silicon, creates the machine as **amd64** so OrbStack uses **Rosetta** for x86_64 binaries.
- Refuses to proceed if an existing machine has the wrong architecture.
- Starts the machine.
- Uploads the machine provisioning script into the Linux guest.
- Prints the `orbctl run` command for guest setup, using the **absolute installer path you passed in**.

The host script does **not** copy the installer anywhere on macOS. OrbStack shares your Mac filesystem inside Linux at the same absolute paths (for example `/Users/you/Downloads/installer.bin`). The guest setup script copies the installer into the VM before running it.

### `setup_fpga_devbox_machine.sh`

Runs inside the OrbStack Linux machine.

Responsibilities:
- Verifies the machine is **x86_64** before installing (Vivado/Vitis are not available for arm64 Linux).
- Copies the installer from the macOS path you provided into `~/xilinx-installer` inside the VM.
- Extracts the `.bin` or `.tar.gz` payload and runs **`xsetup`** in batch mode (the `.bin` wrapper itself does not accept `--agree` / `--batch`).
- For **`.bin` / SDI** installers, ensures an AMD **auth token** exists at `~/.Xilinx/wi_authentication_key` before batch install (interactive `AuthTokenGen`, or `XILINX_AMD_EMAIL` / `XILINX_AMD_PASSWORD`).
- Uses `config/vitis_unified_2025.2.install_config` by default when present beside the script (override with `INSTALL_CONFIG`).
- Removes any stale install config in the VM, copies the active config to `~/install_config.txt`, filters invalid module names, and compiles it for `xsetup`.
- Applies OrbStack-specific **XRDP** systemd overrides so `xrdp` starts reliably in the container environment.
- Installs **XFCE** and Linux dependencies.
- Installs the **OSS CAD Suite** (yosys, nextpnr, **Verilator**, **Icarus Verilog**, gtkwave, ...) into `~/oss-cad-suite` and sources it from `~/.bashrc`, before the Vitis installation.
- Adds `settings64.sh` to the login shell environment.

### `fpga_devbox.sh`

Runs on the macOS host.

Responsibilities:
- Starts the OrbStack machine if needed.
- Verifies that XRDP is active.
- Opens the Linux desktop session via Windows App or Microsoft Remote Desktop.
- Verifies the machine is **amd64** / **x86_64** before launching tools.
- Refreshes the guest-side launcher scripts (`~/bin/fpga-launch-gui`, `~/bin/start-vivado-gui`, `~/bin/start-vitis-gui`) on every run, so existing machines pick up fixes without re-running full setup.
- Optionally starts **Vivado** or **Vitis** by calling those guest scripts (the launch logic lives in the VM, not inline in the host script).
- Can install/remove an **autostart** entry so a tool launches automatically on RDP login.

#### How GUI launch works

The host script never runs `vivado`/`vitis` directly. It invokes the guest helper `~/bin/start-<tool>-gui`, which:

1. Sources `~/.xilinx-settings.sh` (with `nounset` toggled off, since AMD's `settings64.sh` references unset variables).
2. Discovers the active XRDP desktop session environment and imports `DISPLAY`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS`, and `XDG_RUNTIME_DIR`. It deliberately prefers a desktop process (for example `xfce4-session`) that exposes the **session D-Bus**, because the Electron-based Vitis IDE will not start without `DBUS_SESSION_BUS_ADDRESS`.
3. Launches the tool through the per-user **systemd manager** (`systemd-run --user -p KillMode=process`), so the GUI runs in its own cgroup, independent of the transient `orbctl run` shell, and reliably survives after the launcher returns. If `systemd-run` is unavailable it falls back to a detached `setsid` launch.

## Quick start

### 1. Clone the repository

```bash
git clone <your-repo-url>
cd fpga-devbox
```

### 2. Make the scripts executable

```bash
chmod +x setup_fpga_devbox_host.sh setup_fpga_devbox_machine.sh fpga_devbox.sh
```

### 3. Run the host setup

Pass the **absolute** path to your downloaded Vitis Unified installer:

```bash
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.bin
```

or:

```bash
./setup_fpga_devbox_host.sh /absolute/path/to/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_*.bin
```

or:

```bash
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.tar.gz
```

The script will create or start the default OrbStack machine and then print the exact `orbctl run` command needed for guest setup.

### 4. Run the guest setup inside the machine

Run from macOS using the repo script path and your installer path. The guest script auto-uses `config/vitis_unified_2025.2.install_config` when `INSTALL_CONFIG` is not set.

```bash
orbctl run -m xilinx-dev bash -lc '/Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_....bin"'
```

Use the same absolute macOS installer path you passed to the host script. The guest copies the installer and install config into the VM before running `xsetup`.

For **SDI / `.bin`** installers, the guest needs an AMD auth token before download+install. If `orbctl run` is non-interactive, open an interactive shell and run the setup script from there so it can prompt for AMD credentials.

Open an interactive shell in the VM (`orbctl run` has no `-it` flag):

```bash
orbctl run -m xilinx-dev
```

Inside that shell:

```bash
/Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_....bin"
```

The script extracts the installer, finds the real `xsetup` path, runs `AuthTokenGen`, and then continues the batch install. You can also pass credentials for one-shot automation (token valid ~7 days):

```bash
orbctl run -m xilinx-dev bash -lc 'XILINX_AMD_EMAIL=you@example.com XILINX_AMD_PASSWORD=secret /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
```

Depending on installer size, selected modules, and download speed, this step may take a while.

## Usage

Once the machine has been provisioned, `fpga_devbox.sh` is the main entry point for daily use.

### Open the Linux desktop

```bash
./fpga_devbox.sh
```

or:

```bash
./fpga_devbox.sh desktop
```

This starts OrbStack and the machine, waits for XRDP and the RDP TCP port to be reachable, writes an `.rdp` file, and opens the Linux desktop via Windows App or Microsoft Remote Desktop. On a cold macOS startup this can take a minute or two.

The launcher pre-fills the Linux username in the RDP file. If you have not set a Linux password for that user yet, set one once:

```bash
orbctl run -m xilinx-dev bash -lc 'sudo passwd "$USER"'
```

Use that password when Windows App / Microsoft Remote Desktop prompts you.

### Open the desktop and start Vivado

```bash
./fpga_devbox.sh vivado
```

The script opens the RDP desktop first, then the guest helper waits for an active XRDP login session. **You must be logged into the RDP desktop** for the GUI to appear, because the tool is launched into that session's environment. If the desktop was not already logged in, log in when Windows App / Microsoft Remote Desktop opens; the helper then starts Vivado in your session. Tune the wait with `GUI_SESSION_TIMEOUT=300` if needed.

To pass a machine name and a working directory:

```bash
./fpga_devbox.sh vivado xilinx-dev /home/<linux-user>/fpga-projects/mydesign
```

### Open the desktop and start Vitis

```bash
./fpga_devbox.sh vitis
```

Vitis uses the same flow. Vitis is an Electron/Theia application and needs the session D-Bus, which the guest helper imports automatically.

To pass a machine name and a workspace directory:

```bash
./fpga_devbox.sh vitis xilinx-dev /home/<linux-user>/vitis-workspace
```

### Auto-launch a tool on every RDP login

Inspired by the [vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) project, which starts Vivado as part of its desktop session, you can have a tool launch automatically whenever you log into the RDP desktop. This is the most reliable model, because the tool starts as a native child of the desktop session:

```bash
./fpga_devbox.sh autostart vivado   # auto-launch Vivado on every RDP login
./fpga_devbox.sh autostart vitis    # auto-launch Vitis on every RDP login
./fpga_devbox.sh autostart status   # show what is configured
./fpga_devbox.sh autostart off      # disable auto-launch
```

This writes an XFCE autostart entry (`~/.config/autostart/fpga-devbox-<tool>.desktop`) in the VM that runs the same guest launcher. On-demand `./fpga_devbox.sh vivado|vitis` still works independently.

## Typical workflow

A common workflow for day-to-day development:

1. Start the Linux desktop:
   ```bash
   ./fpga_devbox.sh
   ```
2. Start Vivado or Vitis:
   ```bash
   ./fpga_devbox.sh vivado
   ```
   or
   ```bash
   ./fpga_devbox.sh vitis
   ```
3. Use the Linux desktop like a normal FPGA workstation.
4. Run Vivado/Vitis GUI when needed.
5. Run Tcl flows, Verilator, or Icarus Verilog from terminals inside the machine.

## Tooling installed in the guest

After setup, the machine is intended to provide:

- `vivado`
- `vitis`
- `xrdp`
- `xfce4`
- The full [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) (extracted to `~/oss-cad-suite` and sourced from `~/.bashrc`), which bundles open-source tools such as `yosys`, `nextpnr`, `verilator`, `iverilog`/`vvp`, `gtkwave`, and more.

`verilator` and `iverilog` are no longer installed via `apt`; they come from the OSS CAD Suite. Because the suite is sourced in `~/.bashrc`, its tools are available in interactive shells inside the machine.

## Configuration

The scripts support a few environment overrides.

### Host-side overrides

```bash
MACHINE=my-fpga-box ./setup_fpga_devbox_host.sh /absolute/path/to/installer.bin
DISTRO=ubuntu:noble ./setup_fpga_devbox_host.sh /absolute/path/to/installer.bin
ARCH=amd64 ./setup_fpga_devbox_host.sh /absolute/path/to/installer.bin
```

`ARCH` defaults to `amd64` on Apple Silicon. On Intel Macs, new machines are also created as `amd64` because Vivado/Vitis require x86_64 Linux.

## Apple Silicon and Rosetta

The AMD/Xilinx Linux toolchain is **x86_64 only**. On Apple Silicon Macs, OrbStack does not run Vivado inside a native arm64 Ubuntu machine; it creates an **amd64** machine and uses **Rosetta** to execute x86_64 Linux binaries with much better performance than QEMU-style emulation.

Machine architecture is fixed when the VM is created. If you already created `xilinx-dev` as arm64, delete and recreate it:

```bash
orbctl delete xilinx-dev
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.bin
```

Verify the guest architecture before or after setup:

```bash
orbctl info xilinx-dev | grep Architecture
orbctl run -m xilinx-dev uname -m    # should print x86_64
```

### Guest-side overrides

Editable install config template (all 2025.2 modules, one per line):

`config/vitis_unified_2025.2.install_config`

By default the guest script uses that file when it sits beside `setup_fpga_devbox_machine.sh`. To override explicitly:

```bash
orbctl run -m xilinx-dev bash -lc 'INSTALL_CONFIG=/Users/<your-mac-user>/Projects/fpga-devbox/config/vitis_unified_2025.2.install_config /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
```

Before installing, the guest script removes stale install configs (`~/install_config.txt`, `~/.Xilinx/install_config.txt`, `~/.xilinx-install-config.compiled.txt`), copies the active config to `~/install_config.txt`, filters unknown module names against the installer, and writes a compiled config for `xsetup`.

Other overrides:

```bash
orbctl run -m xilinx-dev bash -lc 'INSTALL_ROOT=/tools/Xilinx /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
orbctl run -m xilinx-dev bash -lc 'VITIS_VER=2025.2 /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
orbctl run -m xilinx-dev bash -lc 'XRDP_PASSWORD=choose-a-password /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
orbctl run -m xilinx-dev bash -lc 'XILINX_AMD_EMAIL=you@example.com XILINX_AMD_PASSWORD=secret /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
orbctl run -m xilinx-dev bash -lc 'FORCE_AUTH_TOKEN_GEN=1 /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
```

To skip the repo config and use AMD's built-in edition defaults instead:

```bash
orbctl run -m xilinx-dev bash -lc 'INSTALL_CONFIG= /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/Users/<your-mac-user>/Downloads/installer.bin"'
```

To regenerate the module list from your exact installer release:

```bash
orbctl run -m xilinx-dev bash -lc 'cd ~/xilinx-installer/extracted && ./xsetup -b ConfigGen -c ~/install_config.txt'
```

Copy any lines you want into `config/vitis_unified_2025.2.install_config`, then rerun guest setup.

## Verification

Check that XRDP is active:

```bash
orbctl run -m xilinx-dev systemctl status xrdp --no-pager
```

Check that the FPGA tools are visible:

```bash
orbctl run -m xilinx-dev bash -lc 'source ~/.xilinx-settings.sh 2>/dev/null || true; source ~/oss-cad-suite/environment 2>/dev/null || true; which vivado || true; which vitis || true; which verilator; which iverilog; which vvp; which yosys; which nextpnr-ice40 || true'
```

## Why XRDP instead of XQuartz

For Vivado and Vitis, XRDP is generally the better fit because it gives a complete Linux desktop session with a window manager and a more VM-like workflow than individual X11 forwarding. XQuartz can still be useful for one-off GUI apps, but for larger FPGA tools, a full desktop is typically more practical.

## Troubleshooting

### XRDP is not active

On OrbStack, the stock `xrdp` systemd units can fail with `dependency job for xrdp.service failed` because PID tracking for `Type=forking` services does not work in the container environment. The guest setup script applies an OrbStack-specific override that runs `xrdp` and `xrdp-sesman` in foreground mode.

The launcher waits for both the service and the TCP port. If your Mac is slow to start OrbStack after reboot, tune the wait windows:

```bash
START_TIMEOUT=180 XRDP_TIMEOUT=180 ./fpga_devbox.sh
```

If XRDP still fails, check logs and service state:

```bash
orbctl run -m xilinx-dev journalctl -u xrdp-sesman -u xrdp --no-pager
orbctl run -m xilinx-dev systemctl status xrdp-sesman xrdp --no-pager
```

Restart after pulling the latest setup script:

```bash
orbctl run -m xilinx-dev sudo systemctl restart xrdp-sesman xrdp
```

### Vivado or Vitis fails to start

First, make sure you are **logged into the RDP desktop**. The GUI is launched into your active XRDP session, so the helper waits for that session and exits with a message if none appears within `GUI_SESSION_TIMEOUT` seconds.

Check the logs inside the Linux machine:

```bash
orbctl run -m xilinx-dev tail -n 100 /tmp/vivado-gui.log
orbctl run -m xilinx-dev tail -n 100 /tmp/vitis-gui.log
```

The tools run as transient per-user systemd services. Inspect them with:

```bash
orbctl run -m xilinx-dev bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user list-units "fpga-*" --all'
orbctl run -m xilinx-dev bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); journalctl --user -u "fpga-vitis-*" --no-pager | tail -n 100'
```

Verify that the Xilinx settings files exist. AMD installer layouts vary, so the setup script writes `~/.xilinx-settings.sh` to source every available Vivado/Vitis settings script:

```bash
orbctl run -m xilinx-dev bash -lc 'ls /tools/Xilinx/2025.2/{Vivado,Vitis}/settings64.sh /tools/Xilinx/{Vivado,Vitis}/2025.2/settings64.sh 2>/dev/null'
```

If a tool starts but crashes or renders incorrectly under Rosetta, the launcher already preloads `libudev`/`libselinux`/`libz`/`libgdk-x11` by default (borrowed from the vivado-on-silicon-mac project; see the segfault note below). To override or extend that list, set `FPGA_LD_PRELOAD`:

```bash
orbctl run -m xilinx-dev bash -lc 'FPGA_LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libudev.so.1 /usr/lib/x86_64-linux-gnu/libselinux.so.1 /usr/lib/x86_64-linux-gnu/libz.so.1" ~/bin/start-vivado-gui'
```

If RDP prompts for credentials, use the Linux username printed by `fpga_devbox.sh`. Set or reset its password with:

```bash
orbctl run -m xilinx-dev bash -lc 'sudo passwd "$USER"'
```

### Segmentation fault during synthesis/implementation (libudev / WebTalk)

If synth/impl aborts with `An unexpected error has occurred (11) Segmentation fault` and a stack trace through `libudev.so.1(udev_enumerate_scan_devices)` → `libXil_lmgr11.so` → `GetHostInfo`/`WebTalk`, this is the known FlexLM/WebTalk crash under Rosetta x86 emulation: Vivado fingerprints the host via `libudev`, which faults in glibc's allocator under Rosetta.

The devbox addresses this two ways:

1. **`LD_PRELOAD` (primary fix).** The guest launcher resolves `libudev`/`libselinux`/`libz`/`libgdk-x11` (Ubuntu 24.04 layout) and exports them via `LD_PRELOAD` before starting Vivado/Vitis, so the real `libudev` binds to glibc's allocator before FlexLM's `dlopen(RTLD_DEEPBIND)` runs. Because it is exported, the GUI's `launch_runs` child processes inherit it too. This mirrors `vivado-on-silicon-mac`'s `de_start.sh`.

   For **terminal/batch flows** (e.g. `vivado -mode batch -source flow.tcl`, `xsct`, `vitis`, `vitis_hls`), the same preload is applied automatically through real wrapper **scripts** in `~/bin`: `~/.xilinx-settings.sh` (sourced from `~/.bashrc`) resolves the libraries into `FPGA_LD_PRELOAD`, exports it, and puts `~/bin` ahead of the real Xilinx bin dirs on `PATH`. There, `vivado`/`vitis`/`xsct`/`vitis_hls` are symlinks to `~/bin/fpga-tool-shim`, which sets `LD_PRELOAD` and execs the real tool. Because these are real executables on `PATH` (not bash functions), **every** caller gets the preload — including `tclsh` `exec vivado ...`, `make`, and other non-bash callers, not just interactive bash. So you can just run `vivado -mode batch -source flow.tcl` directly — no manual preload needed. To opt out or customize, `export FPGA_LD_PRELOAD=...` (or empty) before the helper is sourced. A fully non-interactive `orbctl run ... bash -c` that never sources `~/.xilinx-settings.sh` won't have `~/bin` on `PATH`, so there, `source ~/.xilinx-settings.sh` first.
2. **WebTalk disabled.** The setup script also writes `catch {config_webtalk -install off}` into `~/.Xilinx/Vivado/Vivado_init.tcl` (and `Vitis_init.tcl`), removing the WebTalk trigger entirely. If you provisioned before this change, re-run guest setup, or add it manually:

```bash
orbctl run -m xilinx-dev bash -lc 'mkdir -p ~/.Xilinx/Vivado && echo "catch {config_webtalk -install off}" >> ~/.Xilinx/Vivado/Vivado_init.tcl'
```

If a crash with the same `libudev` signature somehow persists, run synthesis/implementation in-process (`synth_design`, `opt_design`, `place_design`, `route_design`, `write_bitstream`) instead of via `launch_runs`.

### Installer path is not visible inside Linux

OrbStack should expose macOS paths at the same absolute location. Verify the file is visible from the guest:

```bash
orbctl run -m xilinx-dev ls -lh '/Users/<your-mac-user>/Downloads/Xilinx_Unified_2025.2_....bin'
```

If that fails, confirm OrbStack file sharing is enabled and the path is absolute on macOS.

### Installer fails with `Unrecognized flag : --agree`

The `.bin` download is a Makeself wrapper, not `xsetup`. The guest script extracts it first:

```bash
./FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_....bin --keep --noexec --target ~/xilinx-installer/extracted
./xilinx-installer/extracted/xsetup --agree XilinxEULA,3rdPartyEULA --batch Install --edition "Vitis Unified Software Platform" --location /tools/Xilinx
```

If you hit this error on an older checkout, pull the latest `setup_fpga_devbox_machine.sh` and rerun guest setup.

### Installer fails: generate an authentication token (`AuthTokenGen`)

The SDI `.bin` is a **web-installer client**. It downloads Vivado/Vitis payloads during batch install and requires a token at `~/.Xilinx/wi_authentication_key` (valid about 7 days).

Generate it interactively inside the VM. OrbStack does not support Docker-style `-it`; use an interactive shell and run the setup script there:

```bash
orbctl run -m xilinx-dev
```

Then inside the VM:

```bash
/Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/path/to/installer.bin"
```

The script will extract the installer, find the actual `xsetup`, prompt for your AMD account, and continue installation. Use the same email casing as your AMD account record.

Or pass credentials when rerunning setup:

```bash
orbctl run -m xilinx-dev bash -lc 'XILINX_AMD_EMAIL=you@example.com XILINX_AMD_PASSWORD=secret /Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/path/to/installer.bin"'
```

If you use a **full offline `.tar.gz`** image instead of the SDI `.bin`, auth is not required.

### Installer fails with invalid `Modules` config (for example `Vitis Model Composer`)

Module names change between AMD releases. The guest script filters unknown module names, but the safest path is to edit `config/vitis_unified_2025.2.install_config` and rerun guest setup so the script refreshes `~/install_config.txt` from that source:

```bash
orbctl run -m xilinx-dev bash -lc '/Users/<your-mac-user>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh "/path/to/installer.bin"'
```

### Wrong machine architecture (arm64 instead of amd64)

If setup or `fpga_devbox.sh` reports an architecture mismatch, the VM was likely created before this requirement was enforced:

```bash
orbctl info xilinx-dev | grep Architecture
orbctl delete xilinx-dev
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.bin
```

## Notes

- The setup is designed for **future reuse**, so the scripts are intentionally split into host provisioning, guest provisioning, and daily-launch responsibilities.
- The Linux guest is meant to behave like a persistent FPGA workstation, not a disposable container.
- This repository is a practical base for extending the environment with JTAG tools, additional simulators, board support packages, or project-specific shell wrappers.

### Techniques adopted from vivado-on-silicon-mac

The [vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac) project runs Vivado in an x86 Docker container under Rosetta and exposes it over VNC. We kept our own architecture (OrbStack amd64 VM + XRDP/XFCE), but borrowed three ideas:

- **Launch from within the session, not injected from outside.** That project auto-starts Vivado as part of the desktop session (`de_start.desktop` → `de_start.sh`), so the GUI inherits a correct `DISPLAY`/D-Bus environment. We mirror this with the opt-in `autostart` subcommand, and for on-demand launches we run the tool in the per-user **systemd** manager (`systemd-run --user`) so it lives in a session-independent cgroup rather than the short-lived `orbctl run` shell. This eliminated the intermittent "the launch command prints success but no window appears" failures.
- **Importing the full graphical environment.** The key fix for Vitis (Electron/Theia) was importing `DBUS_SESSION_BUS_ADDRESS` (plus `XAUTHORITY`/`XDG_RUNTIME_DIR`), not just `DISPLAY`.
- **`LD_PRELOAD` shim for Rosetta quirks.** That project preloads `libudev`/`libselinux`/`libz`/`libgdk-x11` (in `de_start.sh`) so they bind to glibc's allocator before Vivado's FlexLM `dlopen(RTLD_DEEPBIND)` runs — without it, `libudev` segfaults in `realloc` (`udev_enumerate_scan_devices`) under Rosetta during synth/impl. We do the same: the guest launcher resolves those libraries (Ubuntu 24.04 layout) and exports the `LD_PRELOAD` **by default** so both the GUI and its `launch_runs` child processes inherit it. For terminal/batch use we go one step further with real wrapper **scripts** in `~/bin` (`vivado`/`vitis`/`xsct`/`vitis_hls` → `fpga-tool-shim`) placed ahead of the Xilinx bin dirs on `PATH`; the shim sets `LD_PRELOAD` and execs the real tool, so every caller gets the preload — including `tclsh` `exec` and `make`, not just interactive bash. Override or extend the list via `FPGA_LD_PRELOAD`.

We did **not** adopt its VNC stack (XRDP works well for us) or its XVC-over-USB JTAG forwarding (out of scope here).
