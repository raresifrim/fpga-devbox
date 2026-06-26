#!/usr/bin/env bash
set -euo pipefail

MACHINE_DEFAULT="xilinx-dev"
TOOL="${1:-desktop}"
MACHINE="${2:-$MACHINE_DEFAULT}"
ARG3="${3:-}"
RDP_PORT="${RDP_PORT:-3389}"
VITIS_VER="${VITIS_VER:-2025.2}"
HOSTNAME="${MACHINE}.orb.local"
RDP_FILE="$HOME/.orbstack-${MACHINE}.rdp"
MAC_RDP_APP="/Applications/Microsoft Remote Desktop.app"

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
need_cmd ssh
need_cmd open

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

if ! orb list | awk '{print $1}' | grep -qx "$MACHINE"; then
  echo "Machine '$MACHINE' not found. Create it first with: orb create ubuntu $MACHINE" >&2
  exit 1
fi

echo "Starting machine: $MACHINE"
orb start "$MACHINE" >/dev/null

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOSTNAME" "systemctl is-active --quiet xrdp" 2>/dev/null; then
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
full address:s:${HOSTNAME}:${RDP_PORT}
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

if [[ -d "$MAC_RDP_APP" ]]; then
  open -a "$MAC_RDP_APP" "$RDP_FILE"
else
  echo "Microsoft Remote Desktop is not installed; connect manually to ${HOSTNAME}:${RDP_PORT}" >&2
fi

sleep 2

case "$TOOL" in
  desktop)
    echo "Desktop opened for $MACHINE"
    ;;
  vivado)
    WORKDIR="${ARG3:-$HOME}"
    ssh "$HOSTNAME" "bash -lc 'mkdir -p \"$WORKDIR\" && source /tools/Xilinx/Vitis/$VITIS_VER/settings64.sh && cd \"$WORKDIR\" && nohup vivado >/tmp/vivado-gui.log 2>&1 &'"
    echo "Vivado launch requested in $MACHINE at $WORKDIR"
    ;;
  vitis)
    WORKDIR="${ARG3:-$HOME/vitis-workspace}"
    ssh "$HOSTNAME" "bash -lc 'mkdir -p \"$WORKDIR\" && source /tools/Xilinx/Vitis/$VITIS_VER/settings64.sh && cd \"$WORKDIR\" && nohup vitis -w \"$WORKDIR\" >/tmp/vitis-gui.log 2>&1 &'"
    echo "Vitis launch requested in $MACHINE with workspace $WORKDIR"
    ;;
esac
