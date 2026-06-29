#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BIN="$SCRIPT_DIR/bin"

MACHINE_DEFAULT="xilinx-dev"
TOOL="${1:-desktop}"
if [[ "$TOOL" == "autostart" ]]; then
  AUTOSTART_TARGET="${2:-}"
  MACHINE="${3:-$MACHINE_DEFAULT}"
  ARG3=""
else
  AUTOSTART_TARGET=""
  MACHINE="${2:-$MACHINE_DEFAULT}"
  ARG3="${3:-}"
fi
RDP_PORT="${RDP_PORT:-3389}"
VITIS_VER="${VITIS_VER:-2025.2}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
START_TIMEOUT="${START_TIMEOUT:-120}"
XRDP_TIMEOUT="${XRDP_TIMEOUT:-120}"
GUI_SESSION_TIMEOUT="${GUI_SESSION_TIMEOUT:-180}"
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
  $(basename "$0") autostart vivado   # auto-launch Vivado on every RDP login
  $(basename "$0") autostart vitis    # auto-launch Vitis on every RDP login
  $(basename "$0") autostart off      # disable auto-launch

Notes:
  - For vivado/vitis/desktop, the 2nd argument is the OrbStack machine name and
    the 3rd argument is the Vivado project / Vitis workspace directory in Linux.
  - For 'autostart', the 2nd argument is the tool (vivado|vitis|off) and the
    optional 3rd argument is the machine name.
  - Set VITIS_VER to override the default version (2025.2).
  - Set GUI_SESSION_TIMEOUT to control how long tool launch waits for RDP login.
USAGE
}

need_cmd orb
need_cmd orbctl
need_cmd nc
need_cmd open

orb_machine() {
  orbctl run -m "$MACHINE" "$@"
}

machine_arch() {
  orbctl info "$MACHINE" 2>/dev/null | awk -F': ' '/^Architecture:/ {print $2; exit}'
}

wait_until() {
  local timeout="$1"
  local message="$2"
  shift 2
  local start
  start="$(date +%s)"

  while true; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout )); then
      echo "Timed out waiting for: $message" >&2
      return 1
    fi
    sleep 2
  done
}

rdp_username() {
  orb_machine id -un 2>/dev/null || true
}

rdp_password_state() {
  local user="$1"
  [[ -n "$user" ]] || return 0
  orb_machine bash -lc 'sudo passwd -S "$1" 2>/dev/null | awk "{print \$2; exit}"' _ "$user" 2>/dev/null || true
}

ensure_guest_xilinx_settings_helper() {
  orb_machine bash -lc '
    set -euo pipefail
    install_root="$1"
    vitis_ver="$2"

    cat > "$HOME/.xilinx-settings.sh" <<SH
#!/usr/bin/env bash
# Source all available Xilinx settings scripts. AMD installer layouts vary, and
# Vitis flows can require both Vivado and Vitis environments.
found=0
had_nounset=0
case "\$-" in
  *u*) had_nounset=1; set +u ;;
esac
for settings in \\
  "$install_root/$vitis_ver/Vivado/settings64.sh" \\
  "$install_root/Vivado/$vitis_ver/settings64.sh" \\
  "$install_root/$vitis_ver/Vitis/settings64.sh" \\
  "$install_root/Vitis/$vitis_ver/settings64.sh"; do
  if [[ -f "\$settings" ]]; then
    source "\$settings"
    found=1
  fi
done
(( had_nounset )) && set -u

# Resolve the Rosetta libudev workaround preload once and export it so the
# ~/bin tool shims (vivado/vitis/xsct/vitis_hls) and manual runs reuse it.
# Ubuntu 24.04 layout. Export FPGA_LD_PRELOAD yourself to override.
if [[ -z "\${FPGA_LD_PRELOAD:-}" ]]; then
  FPGA_LD_PRELOAD=""
  for _fpga_lib in libudev.so.1 libselinux.so.1 libz.so.1 libgdk-x11-2.0.so.0; do
    _fpga_path="\$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -maxdepth 1 -name "\$_fpga_lib" -print -quit 2>/dev/null)"
    [[ -n "\$_fpga_path" ]] && FPGA_LD_PRELOAD="\${FPGA_LD_PRELOAD:+\$FPGA_LD_PRELOAD }\$_fpga_path"
  done
  unset _fpga_lib _fpga_path
fi
export FPGA_LD_PRELOAD
# Make the ~/bin tool shims take precedence over the real Xilinx bin dirs so
# every caller (interactive bash, tclsh exec, make, ...) gets the preload.
case "\$PATH" in
  "\$HOME/bin:"*) ;;
  *) PATH="\$HOME/bin:\$PATH"; export PATH ;;
esac

(( found ))
SH
    chmod +x "$HOME/.xilinx-settings.sh"

    if ! grep -q '\''source "$HOME/.xilinx-settings.sh"'\'' "$HOME/.bashrc"; then
      echo '\''source "$HOME/.xilinx-settings.sh" 2>/dev/null || true'\'' >> "$HOME/.bashrc"
    fi
  ' _ "$INSTALL_ROOT" "$VITIS_VER"
}

# Write (or refresh) the guest-side GUI launcher scripts inside the VM. These own
# the full launch logic so existing machines pick up fixes without re-running the
# full guest setup. Kept in sync with setup_fpga_devbox_machine.sh.
write_guest_launchers() {
  # Install the ~/bin helpers by copying them from the repo bin/ directory, which
  # OrbStack exposes inside the VM at its absolute macOS path via virtiofs. The
  # repo bin/ is the single source of truth (kept in sync with
  # setup_fpga_devbox_machine.sh); editing a file there is enough to update the VM.
  orb_machine bash -lc '
    set -euo pipefail
    REPO_BIN="$1"
    if [[ ! -d "$REPO_BIN" || ! -r "$REPO_BIN" ]]; then
      echo "Repo bin/ directory is not readable inside the VM: $REPO_BIN" >&2
      echo "The fpga-devbox repo must live on a macOS path that OrbStack mounts" >&2
      echo "into the VM (under /Users, /Volumes, /private, ...). Move the repo there" >&2
      echo "and rerun." >&2
      exit 1
    fi
    mkdir -p "$HOME/bin"
    cp "$REPO_BIN"/fpga-launch-gui "$REPO_BIN"/start-vivado-gui "$REPO_BIN"/start-vitis-gui "$REPO_BIN"/fpga-tool-shim "$REPO_BIN"/fpga-usb-setup "$REPO_BIN"/fpga-uart "$HOME/bin/"
    chmod +x \
      "$HOME/bin/fpga-launch-gui" \
      "$HOME/bin/start-vivado-gui" \
      "$HOME/bin/start-vitis-gui" \
      "$HOME/bin/fpga-tool-shim" \
      "$HOME/bin/fpga-usb-setup" \
      "$HOME/bin/fpga-uart"
    for t in vivado vitis xsct vitis_hls; do ln -sf fpga-tool-shim "$HOME/bin/$t"; done
  ' _ "$REPO_BIN"

  orb_machine bash -lc 'grep -q '\''export PATH="$HOME/bin:$PATH"'\'' "$HOME/.bashrc" || echo '\''export PATH="$HOME/bin:$PATH"'\'' >> "$HOME/.bashrc"'
}

# Auto-launch a tool when the XFCE session starts (adopted from the
# vivado-on-silicon-mac de_start.desktop model). Launching from within the
# session is the most reliable path: the tool inherits the real DISPLAY/DBUS
# environment with no external injection.
install_autostart() {
  local tool="$1"
  orb_machine bash -lc '
    set -euo pipefail
    tool="$1"
    mkdir -p "$HOME/.config/autostart"
    dest="$HOME/.config/autostart/fpga-devbox-$tool.desktop"
    cat > "$dest" <<EOF
[Desktop Entry]
Type=Application
Name=FPGA Devbox: $tool
Comment=Auto-launch $tool when the XFCE desktop session starts
Exec=$HOME/bin/start-$tool-gui
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    echo "Installed autostart entry: $dest"
    echo "$tool will launch automatically on the next RDP login."
  ' _ "$tool"
}

remove_autostart() {
  orb_machine bash -lc '
    removed=0
    for f in "$HOME"/.config/autostart/fpga-devbox-*.desktop; do
      [[ -e "$f" ]] || continue
      rm -f "$f"
      echo "Removed $f"
      removed=1
    done
    (( removed )) || echo "No FPGA Devbox autostart entries were installed."
  '
}

status_autostart() {
  orb_machine bash -lc '
    shopt -s nullglob
    entries=("$HOME"/.config/autostart/fpga-devbox-*.desktop)
    if (( ${#entries[@]} == 0 )); then
      echo "Autostart: disabled (no entries installed)."
    else
      echo "Autostart entries installed:"
      for f in "${entries[@]}"; do echo "  $(basename "$f")"; done
    fi
  '
}

print_rdp_login_hint() {
  local user="$1"
  local state="$2"

  if [[ -n "$user" ]]; then
    echo "RDP username: $user"
  fi

  if [[ "$state" != "P" ]]; then
    cat <<MSG
RDP needs a Linux password for that user. If you have not set one yet, run:
  orbctl run -m $MACHINE bash -lc 'sudo passwd "$USER"'

Then use that password in Windows App / Microsoft Remote Desktop.
MSG
  fi
}

case "$TOOL" in
  desktop|vivado|vitis|autostart) ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "Unknown action: $TOOL" >&2
    usage
    exit 1
    ;;
esac

if [[ "$TOOL" == "autostart" ]]; then
  case "$AUTOSTART_TARGET" in
    vivado|vitis|off|none|status) ;;
    *)
      echo "Usage: $(basename "$0") autostart <vivado|vitis|off|status>" >&2
      exit 1
      ;;
  esac
fi

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

echo "Waiting for machine command channel..."
wait_until "$START_TIMEOUT" "machine '$MACHINE' to accept commands" \
  orb_machine true

echo "Waiting for XRDP service..."
if ! wait_until "$XRDP_TIMEOUT" "XRDP service in '$MACHINE'" \
  orb_machine systemctl is-active --quiet xrdp; then
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

echo "Waiting for RDP port ${RDP_HOST}:${RDP_PORT}..."
wait_until "$XRDP_TIMEOUT" "RDP port ${RDP_HOST}:${RDP_PORT}" \
  nc -z -w 1 "$RDP_HOST" "$RDP_PORT"

RDP_USER="$(rdp_username)"
RDP_PASSWORD_STATE="$(rdp_password_state "$RDP_USER")"
ensure_guest_xilinx_settings_helper
write_guest_launchers

if [[ "$TOOL" == "autostart" ]]; then
  case "$AUTOSTART_TARGET" in
    vivado|vitis)
      install_autostart "$AUTOSTART_TARGET"
      ;;
    off|none)
      remove_autostart
      exit 0
      ;;
    status)
      status_autostart
      exit 0
      ;;
  esac
fi

cat > "$RDP_FILE" <<RDP
full address:s:${RDP_HOST}:${RDP_PORT}
username:s:${RDP_USER}
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

print_rdp_login_hint "$RDP_USER" "$RDP_PASSWORD_STATE"

sleep 2

case "$TOOL" in
  desktop)
    echo "Desktop opened for $MACHINE"
    ;;
  autostart)
    echo "Autostart for '$AUTOSTART_TARGET' is configured."
    echo "Log into the RDP desktop (now opening) and it will launch automatically."
    ;;
  vivado)
    WORKDIR="$ARG3"
    orb_machine bash -lc 'FPGA_GUI_SESSION_TIMEOUT="$2" exec "$HOME/bin/start-vivado-gui" "$1"' _ "$WORKDIR" "$GUI_SESSION_TIMEOUT"
    echo "Vivado launch requested in $MACHINE at ${WORKDIR:-guest home}"
    ;;
  vitis)
    WORKDIR="$ARG3"
    orb_machine bash -lc 'FPGA_GUI_SESSION_TIMEOUT="$2" exec "$HOME/bin/start-vitis-gui" "$1"' _ "$WORKDIR" "$GUI_SESSION_TIMEOUT"
    echo "Vitis launch requested in $MACHINE with workspace ${WORKDIR:-guest ~/vitis-workspace}"
    ;;
esac
