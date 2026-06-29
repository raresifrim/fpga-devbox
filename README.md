# fpga-devbox

OrbStack-based FPGA dev environment on macOS: Ubuntu VM + XRDP/XFCE for **Vivado/Vitis 2025.2**, plus **OSS CAD Suite** (Verilator, Yosys, etc.) in the guest.

## Requirements

- macOS with **Homebrew**
- **OrbStack** (installed by host setup if missing)
- **Apple Silicon**: VM is **amd64** (Rosetta) — Vivado/Vitis are x86_64 only
- **Vitis Unified 2025.2** Linux installer (`.bin`, SDI `.bin`, or offline `.tar.gz`)
- SDI/`.bin` installers: AMD account + one-time auth token (guest script handles this)

## First-time setup

```bash
git clone <your-repo-url> && cd fpga-devbox
chmod +x setup_fpga_devbox_host.sh setup_fpga_devbox_machine.sh fpga_devbox.sh

# 1) Host: create/start VM, upload guest setup script
./setup_fpga_devbox_host.sh /absolute/path/to/Xilinx_Unified_2025.2_*.bin

# 2) Guest: install tools (long; use interactive shell for SDI auth if needed)
orbctl run -m xilinx-dev
# inside VM:
/Users/<you>/Projects/fpga-devbox/setup_fpga_devbox_machine.sh \
  "/Users/<you>/Downloads/installer.bin" \
  "/Users/<you>/Projects/fpga-devbox"
```

Install config defaults to `config/vitis_unified_2025.2.install_config`. Guest helpers live in repo `bin/` and are copied to `~/bin` during setup and on every launch.

Set Linux password once (for RDP):

```bash
orbctl run -m xilinx-dev bash -lc 'sudo passwd "$USER"'
```

## Daily use

```bash
./fpga_devbox.sh              # open Linux desktop (RDP)
./fpga_devbox.sh vivado         # desktop + start Vivado
./fpga_devbox.sh vitis          # desktop + start Vitis
./fpga_devbox.sh vivado xilinx-dev /path/to/project
./fpga_devbox.sh autostart vitis   # auto-launch on RDP login
./fpga_devbox.sh autostart off
```

**Log into the RDP desktop** when prompted — GUI tools launch into that session. Tune waits with `GUI_SESSION_TIMEOUT=300` if needed.

Inside the VM (after setup):

```bash
fpga-usb-setup    # passthrough USB: free JTAG + fix UART perms
fpga-uart         # open Digilent UART (auto-detect, tio)
```

## Repo layout

```text
bin/                          # guest ~/bin helpers (copied into VM)
config/vitis_unified_2025.2.install_config
setup_fpga_devbox_host.sh     # macOS: create VM
setup_fpga_devbox_machine.sh  # guest: install everything
fpga_devbox.sh                # macOS: daily launcher
```

## USB: JTAG vs UART (Digilent FT2232H)

| OrbStack mode | JTAG (program FPGA) | UART (serial) |
| --- | --- | --- |
| **Forwarded** (`orb serial`) | No (serial bridge only) | Yes — `/dev/cu.usbserial-*…1` |
| **Passthrough / dedicated** | Yes — run `fpga-usb-setup` | Yes — `fpga-uart` or `/dev/ttyUSB*` |

Close Vivado Hardware Manager before using the UART (it holds the whole chip). UART from macOS host also works: `tio /dev/tty.usbserial-<SERIAL>1`.

## Rosetta / synth crashes

Vivado can segfault in `libudev` under Rosetta during synth/impl. The devbox preloads system libs via `~/bin` shims (`vivado`, `vitis`, `xsct`, `vitis_hls`) and disables WebTalk in `Vivado_init.tcl`. Terminal/batch flows get preload automatically when `~/.bashrc` sources `~/.xilinx-settings.sh`. Vitis **GUI** launch skips `LD_PRELOAD` (breaks Electron); Vivado subprocesses from Vitis still use the shims via `PATH`.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| XRDP not active | Re-run guest setup (OrbStack override) or `sudo systemctl restart xrdp-sesman xrdp` |
| GUI doesn't appear | Log into RDP first; check `/tmp/vivado-gui.log` or `/tmp/vitis-gui.log` |
| Auth token error (SDI) | Interactive VM shell + rerun guest setup, or set `XILINX_AMD_EMAIL`/`XILINX_AMD_PASSWORD` |
| Wrong arch (arm64) | `orbctl delete xilinx-dev` and rerun host setup |
| Installer path not found in VM | Use absolute macOS path; repo must be under `/Users/...` (OrbStack mount) |
| Vivado can't see board | Use **passthrough**, not forwarded; run `fpga-usb-setup` |
| No serial port | Close Hardware Manager; passthrough: `fpga-usb-setup` then `fpga-uart` |

Verify tools:

```bash
orbctl run -m xilinx-dev bash -lc 'source ~/.xilinx-settings.sh; source ~/oss-cad-suite/environment; which vivado vitis verilator yosys'
```
