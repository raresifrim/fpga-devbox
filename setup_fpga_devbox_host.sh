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
[[ -f "$MACHINE_SETUP_LOCAL" ]] || { echo "Machine setup script not found: $MACHINE_SETUP_LOCAL" >&2; exit 1; }

need_cmd brew
need_cmd ssh
need_cmd scp
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

if ! orb list | awk 'NR>1 {print $1}' | grep -qx "$MACHINE"; then
  echo "Creating OrbStack machine $MACHINE from $DISTRO"
  orb create "$DISTRO" "$MACHINE"
fi

orb start "$MACHINE" >/dev/null

for _ in $(seq 1 60); do
  if orb shell "$MACHINE" 'echo ok' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! orb shell "$MACHINE" 'echo ok' >/dev/null 2>&1; then
  echo "Machine $MACHINE was created but is not responding to orb shell yet." >&2
  exit 1
fi

MAC_INSTALLER_DIR="$HOME/XilinxInstall"
mkdir -p "$MAC_INSTALLER_DIR"
INSTALLER_BASENAME="$(basename "$INSTALLER_PATH")"
TARGET_INSTALLER="$MAC_INSTALLER_DIR/$INSTALLER_BASENAME"
if [[ "$INSTALLER_PATH" != "$TARGET_INSTALLER" ]]; then
  cp -f "$INSTALLER_PATH" "$TARGET_INSTALLER"
fi
chmod +r "$TARGET_INSTALLER"

MACHINE_SETUP_BASENAME="$(basename "$MACHINE_SETUP_LOCAL")"
orb push "$MACHINE_SETUP_LOCAL" "$MACHINE:~/setup_fpga_devbox_machine.sh"
orb shell "$MACHINE" 'chmod +x ~/setup_fpga_devbox_machine.sh'

cat <<MSG
Host setup complete.

Machine: $MACHINE
Installer staged on host: $TARGET_INSTALLER
Machine setup script uploaded as: ~/setup_fpga_devbox_machine.sh

Next step:
  orb shell $MACHINE '~/setup_fpga_devbox_machine.sh $TARGET_INSTALLER'

After machine setup finishes, use fpga_devbox.sh from macOS to open the desktop or launch Vivado/Vitis.
MSG
