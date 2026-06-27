#!/usr/bin/env bash
set -euo pipefail

MACHINE_DEFAULT="xilinx-dev"
TOOL="${1:-desktop}"
MACHINE="${2:-$MACHINE_DEFAULT}"
ARG3="${3:-}"
RDP_PORT="${RDP_PORT:-3389}"
VITIS_VER="${VITIS_VER:-2025.2}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
RDP_HOST="${MACHINE}.orb.local"
RDP_FILE="$HOME/.orbstack-${MACHINE}.rdp"

detect_rdp_app() {
  if [[ -d "/Applications/Windows App.app" ]]; then
    echo "Windows App"
  elif [[ -d "/Applications/Microsoft Remote Desktop.app" ]]; then
    echo "Microsoft Remote Desktop"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0")                     # open desktop for xilinx-dev
  $(basename "$0") desktop             # same as above
  $(basename "$0") vivado              # open desktop and start Vivado
  $(basename "$0") vitis               # open desktop and start Vitis
  $(basename "$0") vivado xilinx-dev /path/in/linux
  $(basename "$0") vitis  xilinx-dev /path/in/linux

Notes:
  - The 2nd argument is the OrbStack machine name.
  - The 3rd argument is:
      * Vivado: project working directory inside Linux
      * Vitis:  workspace directory inside Linux
  - Set VITIS_VER to override the default version (2025.2).
USAGE
}

need_cmd orb
need_cmd orbctl
need_cmd open

orb_machine() {
  orbctl run -m "$MACHINE" "$@"
}

machine_arch() {
  orbctl info "$MACHINE" 2>/dev/null | awk -F': ' '/^Architecture:/ {print $2; exit}'
}

case "$TOOL" in
  desktop|vivado|vitis) ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "Unknown action: $TOOL" >&2
    usage
    exit 1
    ;;
esac

if ! orb list >/dev/null 2>&1; then
  echo "Starting OrbStack..."
  orb start >/dev/null 2>&1 || true
fi

if ! orbctl list -q | grep -Fxq "$MACHINE"; then
  echo "Machine '$MACHINE' not found. Create it first with setup_fpga_devbox_host.sh" >&2
  exit 1
fi

CURRENT_ARCH="$(machine_arch)"
if [[ -n "$CURRENT_ARCH" && "$CURRENT_ARCH" != "amd64" ]]; then
  cat <<MSG >&2
Machine '$MACHINE' is $CURRENT_ARCH, but Vivado/Vitis require amd64 (x86_64).

Recreate the machine with the host setup script:
  orbctl delete $MACHINE
  ./setup_fpga_devbox_host.sh /absolute/path/to/installer.bin
MSG
  exit 1
fi

echo "Starting machine: $MACHINE"
orb start "$MACHINE" >/dev/null

if ! orb_machine systemctl is-active --quiet xrdp 2>/dev/null; then
  cat <<MSG
XRDP is not active in '$MACHINE'. Install it once inside the machine:
  sudo apt update
  sudo apt install -y xfce4 xfce4-goodies xrdp xorgxrdp dbus-x11
  echo startxfce4 > ~/.xsession
  sudo adduser xrdp ssl-cert
  sudo systemctl enable --now xrdp
Then rerun this script.
MSG
  exit 2
fi

cat > "$RDP_FILE" <<RDP
full address:s:${RDP_HOST}:${RDP_PORT}
prompt for credentials:i:1
administrative session:i:0
authentication level:i:2
use multimon:i:0
screen mode id:i:2
session bpp:i:32
redirectclipboard:i:1
redirectprinters:i:0
redirectsmartcards:i:0
redirectcomports:i:0
redirectposdevices:i:0
redirectdirectx:i:1
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
displayconnectionbar:i:1
gatewayusagemethod:i:4
audiomode:i:0
videoplaybackmode:i:1
devicestoredirect:s:*
drive store redirect:s:*
RDP

MAC_RDP_APP="$(detect_rdp_app || true)"
if [[ -n "$MAC_RDP_APP" ]]; then
  open -a "$MAC_RDP_APP" "$RDP_FILE"
else
  echo "No RDP client found (Windows App or Microsoft Remote Desktop); connect manually to ${RDP_HOST}:${RDP_PORT}" >&2
fi

sleep 2

case "$TOOL" in
  desktop)
    echo "Desktop opened for $MACHINE"
    ;;
  vivado)
    WORKDIR="$ARG3"
    orb_machine bash -lc '
      set -euo pipefail
      workdir="${1:-$HOME}"
      install_root="$2"
      vitis_ver="$3"
      settings="$install_root/Vitis/$vitis_ver/settings64.sh"
      if [[ ! -f "$settings" ]]; then
        echo "Xilinx settings file not found: $settings" >&2
        echo "Finish guest setup before launching Vivado." >&2
        exit 1
      fi
      mkdir -p "$workdir"
      source "$settings"
      cd "$workdir"
      nohup vivado >/tmp/vivado-gui.log 2>&1 &
    ' _ "$WORKDIR" "$INSTALL_ROOT" "$VITIS_VER"
    echo "Vivado launch requested in $MACHINE at ${WORKDIR:-guest home}"
    ;;
  vitis)
    WORKDIR="$ARG3"
    orb_machine bash -lc '
      set -euo pipefail
      workdir="${1:-$HOME/vitis-workspace}"
      install_root="$2"
      vitis_ver="$3"
      settings="$install_root/Vitis/$vitis_ver/settings64.sh"
      if [[ ! -f "$settings" ]]; then
        echo "Xilinx settings file not found: $settings" >&2
        echo "Finish guest setup before launching Vitis." >&2
        exit 1
      fi
      mkdir -p "$workdir"
      source "$settings"
      cd "$workdir"
      nohup vitis -w "$workdir" >/tmp/vitis-gui.log 2>&1 &
    ' _ "$WORKDIR" "$INSTALL_ROOT" "$VITIS_VER"
    echo "Vitis launch requested in $MACHINE with workspace ${WORKDIR:-guest ~/vitis-workspace}"
    ;;
esac
