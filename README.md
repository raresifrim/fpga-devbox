# fpga-devbox

A small set of scripts for provisioning an **OrbStack-based FPGA development VM** on macOS and using it like a persistent Linux desktop for **Vivado**, **Vitis Unified 2025.2**, **Verilator**, and **Icarus Verilog**. The workflow uses an OrbStack Ubuntu machine plus **XRDP + XFCE** so the environment behaves more like a native Linux workstation than a collection of forwarded X11 windows.

## What this repo does

This repository automates three parts of the workflow:

- Host-side setup on macOS, including OrbStack and an RDP client (Windows App or Microsoft Remote Desktop) if needed.
- Guest-side setup inside the OrbStack Linux machine, including XRDP, XFCE, Vitis Unified, Vivado dependencies, Verilator, and Icarus Verilog.
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
- Installs **XFCE**, Linux dependencies, **Verilator**, and **Icarus Verilog**.
- Adds `settings64.sh` to the login shell environment.

### `fpga_devbox.sh`

Runs on the macOS host.

Responsibilities:
- Starts the OrbStack machine if needed.
- Verifies that XRDP is active.
- Opens the Linux desktop session via Windows App or Microsoft Remote Desktop.
- Verifies the machine is **amd64** / **x86_64** before launching tools.
- Optionally starts **Vivado** or **Vitis** in the Linux environment.

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

This starts the OrbStack machine, checks XRDP, and opens the Linux desktop via Windows App or Microsoft Remote Desktop.

### Open the desktop and start Vivado

```bash
./fpga_devbox.sh vivado
```

To pass a machine name and a working directory:

```bash
./fpga_devbox.sh vivado xilinx-dev /Users/<your-mac-user>/fpga-projects/mydesign
```

### Open the desktop and start Vitis

```bash
./fpga_devbox.sh vitis
```

To pass a machine name and a workspace directory:

```bash
./fpga_devbox.sh vitis xilinx-dev /Users/<your-mac-user>/fpga-projects/mydesign/.vitis-workspace
```

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
- `verilator`
- `iverilog`
- `vvp`
- `xrdp`
- `xfce4`

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
orbctl run -m xilinx-dev bash -lc 'which vivado || true; which vitis || true; which verilator; which iverilog; which vvp'
```

## Why XRDP instead of XQuartz

For Vivado and Vitis, XRDP is generally the better fit because it gives a complete Linux desktop session with a window manager and a more VM-like workflow than individual X11 forwarding. XQuartz can still be useful for one-off GUI apps, but for larger FPGA tools, a full desktop is typically more practical.

## Troubleshooting

### XRDP is not active

On OrbStack, the stock `xrdp` systemd units can fail with `dependency job for xrdp.service failed` because PID tracking for `Type=forking` services does not work in the container environment. The guest setup script applies an OrbStack-specific override that runs `xrdp` and `xrdp-sesman` in foreground mode.

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

Check the logs inside the Linux machine:

```bash
orbctl run -m xilinx-dev tail -n 100 /tmp/vivado-gui.log
orbctl run -m xilinx-dev tail -n 100 /tmp/vitis-gui.log
```

Verify that the Xilinx settings file exists:

```bash
orbctl run -m xilinx-dev ls /tools/Xilinx/Vitis/2025.2/settings64.sh
```

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
