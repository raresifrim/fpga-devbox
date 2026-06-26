#!/usr/bin/env bash
set -euo pipefail

MACHINE="${MACHINE:-xilinx-dev}"
DISTRO="${DISTRO:-ubuntu:noble}"
INSTALLER_PATH="${1:-}"
MACHINE_SETUP_LOCAL="${MACHINE_SETUP_LOCAL:-$PWD/setup_fpga_devbox_machine.sh}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

orb_machine() {
  orbctl run -m "$MACHINE" "$@"
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") /absolute/path/to/Xilinx_Unified_2025.2_*.bin|*.tar.gz

Environment overrides:
  MACHINE=xilinx-dev
  DISTRO=ubuntu:noble
  MACHINE_SETUP_LOCAL=./setup_fpga_devbox_machine.sh
USAGE
}

[[ -n "$INSTALLER_PATH" ]] || { usage; exit 1; }
[[ -e "$INSTALLER_PATH" ]] || { echo "Installer not found: $INSTALLER_PATH" >&2; exit 1; }
[[ "$INSTALLER_PATH" == /* ]] || { echo "Installer path must be absolute: $INSTALLER_PATH" >&2; exit 1; }
INSTALLER_PATH="$(cd "$(dirname "$INSTALLER_PATH")" && pwd)/$(basename "$INSTALLER_PATH")"
[[ -f "$MACHINE_SETUP_LOCAL" ]] || { echo "Machine setup script not found: $MACHINE_SETUP_LOCAL" >&2; exit 1; }

need_cmd brew
need_cmd osascript

brew list --cask orbstack >/dev/null 2>&1 || brew install --cask orbstack

if brew info --cask windows-app >/dev/null 2>&1; then
  brew list --cask windows-app >/dev/null 2>&1 || brew install --cask windows-app
else
  brew list --cask microsoft-remote-desktop >/dev/null 2>&1 || brew install --cask microsoft-remote-desktop
fi

hash -r
need_cmd orb

# OrbStack CLI may be installed before the app has finished first-launch initialization.
open -a OrbStack || true
for _ in $(seq 1 60); do
  if orb status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! orb status >/dev/null 2>&1; then
  echo "OrbStack is installed but not ready yet." >&2
  echo "Open OrbStack.app once, allow any requested permissions, then rerun this script." >&2
  exit 1
fi

orb start >/dev/null 2>&1 || true

if ! orb list | awk '{print $1}' | grep -qx "$MACHINE"; then
  echo "Creating OrbStack machine $MACHINE from $DISTRO"
  orb create "$DISTRO" "$MACHINE"
fi

orb start "$MACHINE" >/dev/null

for _ in $(seq 1 60); do
  if orb_machine echo ok >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! orb_machine echo ok >/dev/null 2>&1; then
  echo "Machine $MACHINE was created but is not responding to orbctl run yet." >&2
  exit 1
fi

if ! orbctl push -m "$MACHINE" "$MACHINE_SETUP_LOCAL" setup_fpga_devbox_machine.sh 2>/dev/null; then
  orb_machine cp "$MACHINE_SETUP_LOCAL" ~/setup_fpga_devbox_machine.sh
fi
orb_machine chmod +x ~/setup_fpga_devbox_machine.sh

cat <<MSG
Host setup complete.

Machine: $MACHINE
Installer on host: $INSTALLER_PATH
Machine setup script uploaded as: ~/setup_fpga_devbox_machine.sh

Next step:
  orbctl run -m $MACHINE ~/setup_fpga_devbox_machine.sh '$INSTALLER_PATH'

The guest script copies the installer from that macOS path into the VM before installing.
After machine setup finishes, use fpga_devbox.sh from macOS to open the desktop or launch Vivado/Vitis.
MSG
