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

brew list --cask orbstack >/dev/null 2>&1 || brew install --cask orbstack
brew list --cask microsoft-remote-desktop >/dev/null 2>&1 || brew install --cask microsoft-remote-desktop

hash -r
need_cmd orb

orb start >/dev/null 2>&1 || true

if ! orb list | awk '{print $1}' | grep -qx "$MACHINE"; then
  echo "Creating OrbStack machine $MACHINE from $DISTRO"
  orb create "$DISTRO" "$MACHINE"
fi

orb start "$MACHINE" >/dev/null
HOSTNAME="${MACHINE}.orb.local"

for _ in $(seq 1 30); do
  if ssh -o BatchMode=yes -o ConnectTimeout=3 "$HOSTNAME" 'echo ok' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

MAC_INSTALLER_DIR="$HOME/XilinxInstall"
mkdir -p "$MAC_INSTALLER_DIR"
INSTALLER_BASENAME="$(basename "$INSTALLER_PATH")"
TARGET_INSTALLER="$MAC_INSTALLER_DIR/$INSTALLER_BASENAME"
if [[ "$INSTALLER_PATH" != "$TARGET_INSTALLER" ]]; then
  cp -f "$INSTALLER_PATH" "$TARGET_INSTALLER"
fi
chmod +r "$TARGET_INSTALLER"

scp "$MACHINE_SETUP_LOCAL" "$HOSTNAME":~/setup_fpga_devbox_machine.sh
ssh "$HOSTNAME" 'chmod +x ~/setup_fpga_devbox_machine.sh'

cat <<MSG
Host setup complete.

Next step:
  ssh $HOSTNAME '~/setup_fpga_devbox_machine.sh /Users/'"$USER"'/XilinxInstall/'"$INSTALLER_BASENAME"''

After machine setup finishes, copy fpga_devbox.sh to somewhere in your PATH and use it from macOS.
MSG
