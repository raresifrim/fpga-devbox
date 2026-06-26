# fpga-devbox

A small set of scripts for provisioning an **OrbStack-based FPGA development VM** on macOS and using it like a persistent Linux desktop for **Vivado**, **Vitis Unified 2025.2**, **Verilator**, and **Icarus Verilog**. The workflow uses an OrbStack Ubuntu machine plus **XRDP + XFCE** so the environment behaves more like a native Linux workstation than a collection of forwarded X11 windows.

## What this repo does

This repository automates three parts of the workflow:

- Host-side setup on macOS, including OrbStack and Microsoft Remote Desktop if needed.
- Guest-side setup inside the OrbStack Linux machine, including XRDP, XFCE, Vitis Unified, Vivado dependencies, Verilator, and Icarus Verilog.
- Daily startup through a launcher script that can open the Linux desktop or launch Vivado/Vitis in the machine session.

## Repository layout

```text
.
├── setup_fpga_devbox_host.sh
├── setup_fpga_devbox_machine.sh
├── fpga_devbox.sh
└── README.md
```

## Requirements

Before using the scripts, make sure the following are already true:

- macOS host with **Homebrew** installed.
- **OrbStack** can be installed on the host, or will be installed by the host setup script.
- The **AMD/Xilinx Vitis Unified 2025.2 Linux installer** has already been downloaded, either as a `.bin` self-extracting installer or a `.tar.gz` single-file package.
- Enough free disk space is available for Vitis/Vivado and device support packages.

## Scripts

### `setup_fpga_devbox_host.sh`

Runs on the macOS host.

Responsibilities:
- Installs OrbStack if missing.
- Installs Microsoft Remote Desktop if missing.
- Creates an OrbStack Ubuntu machine named `xilinx-dev` by default.
- Starts the machine.
- Copies the downloaded Vitis installer into `~/XilinxInstall` on the Mac.
- Uploads the machine provisioning script into the Linux guest.

### `setup_fpga_devbox_machine.sh`

Runs inside the OrbStack Linux machine.

Responsibilities:
- Installs **XFCE** and **XRDP** for GUI access.
- Applies the usual XRDP startup environment fix for Ubuntu/XFCE sessions.
- Installs Linux dependencies required by Vivado/Vitis.
- Installs **Verilator** and **Icarus Verilog**.
- Creates a batch config for **Vitis Unified 2025.2** and launches the installer.
- Adds `settings64.sh` to the login shell environment.

### `fpga_devbox.sh`

Runs on the macOS host.

Responsibilities:
- Starts the OrbStack machine if needed.
- Verifies that XRDP is active.
- Opens the Linux desktop session.
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

Pass the path to your downloaded Vitis Unified installer:

```bash
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.bin
```

or:

```bash
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.tar.gz
```

The script will create or start the default OrbStack machine and then print the exact SSH command needed for the guest setup.

### 4. Run the guest setup inside the machine

Run the SSH command printed by the host script. It will look similar to this:

```bash
ssh xilinx-dev.orb.local '~/setup_fpga_devbox_machine.sh /Users/<your-mac-user>/XilinxInstall/Xilinx_Unified_2025.2_....bin'
```

or:

```bash
ssh xilinx-dev.orb.local '~/setup_fpga_devbox_machine.sh /Users/<your-mac-user>/XilinxInstall/Xilinx_Unified_2025.2_....tar.gz'
```

This step installs the Linux desktop stack and the FPGA toolchain. Depending on installer type and bandwidth, it may take a while.

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

This starts the OrbStack machine, checks XRDP, and opens the Linux desktop via Microsoft Remote Desktop.

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
```

### Guest-side overrides

```bash
VITIS_VER=2025.2 ./setup_fpga_devbox_machine.sh /Users/<your-mac-user>/XilinxInstall/Xilinx_Unified_2025.2_....bin
INSTALL_ROOT=/tools/Xilinx ./setup_fpga_devbox_machine.sh /Users/<your-mac-user>/XilinxInstall/Xilinx_Unified_2025.2_....bin
```

## Verification

Check that XRDP is active:

```bash
ssh xilinx-dev.orb.local 'systemctl status xrdp --no-pager'
```

Check that the FPGA tools are visible:

```bash
ssh xilinx-dev.orb.local 'bash -lc "which vivado || true; which vitis || true; which verilator; which iverilog; which vvp"'
```

## Why XRDP instead of XQuartz

For Vivado and Vitis, XRDP is generally the better fit because it gives a complete Linux desktop session with a window manager and a more VM-like workflow than individual X11 forwarding. XQuartz can still be useful for one-off GUI apps, but for larger FPGA tools, a full desktop is typically more practical.

## Troubleshooting

### XRDP is not active

```bash
ssh xilinx-dev.orb.local 'sudo systemctl restart xrdp && systemctl status xrdp --no-pager'
```

### Vivado or Vitis fails to start

Check the logs inside the Linux machine:

```bash
ssh xilinx-dev.orb.local 'tail -n 100 /tmp/vivado-gui.log'
ssh xilinx-dev.orb.local 'tail -n 100 /tmp/vitis-gui.log'
```

Verify that the Xilinx settings file exists:

```bash
ssh xilinx-dev.orb.local 'ls /tools/Xilinx/Vitis/2025.2/settings64.sh'
```

### Installer path is not visible inside Linux

```bash
ssh xilinx-dev.orb.local 'ls -lh /Users/<your-mac-user>/XilinxInstall/'
```

## Notes

- The setup is designed for **future reuse**, so the scripts are intentionally split into host provisioning, guest provisioning, and daily-launch responsibilities.
- The Linux guest is meant to behave like a persistent FPGA workstation, not a disposable container.
- This repository is a practical base for extending the environment with JTAG tools, additional simulators, board support packages, or project-specific shell wrappers.
