#!/usr/bin/env bash
set -euo pipefail

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
  orb_machine bash -lc 'mkdir -p "$HOME/bin"; cat > "$HOME/bin/fpga-launch-gui"; chmod +x "$HOME/bin/fpga-launch-gui"' <<'GUESTEOF'
#!/usr/bin/env bash
# Launch a Xilinx GUI tool (vivado|vitis) inside the active XRDP desktop session.
# Generated by fpga-devbox; safe to regenerate.
set -uo pipefail

tool="${1:-}"
workdir_arg="${2:-}"
session_timeout="${FPGA_GUI_SESSION_TIMEOUT:-180}"

case "$tool" in
  vivado) logfile="/tmp/vivado-gui.log"; default_workdir="$HOME" ;;
  vitis)  logfile="/tmp/vitis-gui.log";  default_workdir="$HOME/vitis-workspace" ;;
  *) echo "Usage: $(basename "$0") <vivado|vitis> [workdir]" >&2; exit 2 ;;
esac
workdir="${workdir_arg:-$default_workdir}"

# 1) Source the Xilinx tool environment. AMD settings64.sh references unbound
#    variables, so disable nounset while sourcing, then restore it.
if [[ -f "$HOME/.xilinx-settings.sh" ]]; then
  had_nounset=0
  case "$-" in *u*) had_nounset=1; set +u ;; esac
  # shellcheck disable=SC1090
  source "$HOME/.xilinx-settings.sh"
  (( had_nounset )) && set -u
fi

if ! command -v "$tool" >/dev/null 2>&1; then
  echo "$tool is not on PATH after sourcing ~/.xilinx-settings.sh." >&2
  echo "Finish guest setup (Vivado/Vitis install) before launching." >&2
  exit 1
fi

# 2) Import the active graphical desktop session environment. The Electron-based
#    Vitis IDE needs DBUS_SESSION_BUS_ADDRESS, so prefer a desktop process that
#    exposes both DISPLAY and DBUS (e.g. xfce4-session) over Xorg (DISPLAY only).
apply_session_env() {
  local data="$1" line
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*|XAUTHORITY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*) export "$line" ;;
    esac
  done <<< "$data"
  [[ -z "${XAUTHORITY:-}" && -f "$HOME/.Xauthority" ]] && export XAUTHORITY="$HOME/.Xauthority"
}

import_session_env() {
  local uid pid envfile data fallback=""
  uid="$(id -u)"
  for envfile in /proc/[0-9]*/environ; do
    pid="${envfile#/proc/}"; pid="${pid%/environ}"
    [[ -r "$envfile" ]] || continue
    [[ "$(stat -c %u "$envfile" 2>/dev/null)" == "$uid" ]] || continue
    data="$(tr "\0" "\n" < "$envfile" 2>/dev/null)" || continue
    grep -q "^DISPLAY=" <<< "$data" || continue
    if grep -q "^DBUS_SESSION_BUS_ADDRESS=" <<< "$data"; then
      apply_session_env "$data"
      return 0
    fi
    [[ -z "$fallback" ]] && fallback="$data"
  done
  if [[ -n "$fallback" ]]; then
    apply_session_env "$fallback"
    return 0
  fi
  return 1
}

# When launched from inside the desktop (e.g. an XFCE autostart entry) the env is
# already correct, so only discover/wait when DISPLAY+DBUS are not already set.
if [[ -z "${DISPLAY:-}" || -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  start="$(date +%s)"
  until import_session_env && [[ -n "${DISPLAY:-}" ]]; do
    if (( $(date +%s) - start >= session_timeout )); then
      echo "No active XRDP desktop session found (no user process exposes DISPLAY)." >&2
      echo "Log into the RDP desktop first, then rerun." >&2
      exit 1
    fi
    sleep 2
  done
fi
[[ -z "${XAUTHORITY:-}" && -f "$HOME/.Xauthority" ]] && export XAUTHORITY="$HOME/.Xauthority"
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

mkdir -p "$workdir"
cd "$workdir"

# Best-effort: in OrbStack passthrough/dedicated USB mode, free the FT2232H JTAG
# interface (ftdi_sio may grab it) and fix the UART perms so Vivado programming
# and the UART work. Harmless and a no-op in forwarded (orb serial) mode or when
# no board is attached; must never block the tool launch.
[[ -x "$HOME/bin/fpga-usb-setup" ]] && "$HOME/bin/fpga-usb-setup" || true

cmd=("$tool")
[[ "$tool" == "vitis" ]] && cmd=("$tool" -w "$workdir")

echo "Launching $tool on DISPLAY=$DISPLAY (dbus=${DBUS_SESSION_BUS_ADDRESS:+set}); log: $logfile"

# Preload real system libraries so they bind to glibc's allocator before
# Vivado's FlexLM dlopen(RTLD_DEEPBIND) runs; otherwise libudev crashes in
# realloc (udev_enumerate_scan_devices) under Rosetta x86 during synth/impl.
# This mirrors the vivado-on-silicon-mac approach. Paths target the Ubuntu
# 24.04 layout; export FPGA_LD_PRELOAD yourself to override the default list.
if [[ -z "${FPGA_LD_PRELOAD:-}" ]]; then
  _preload=""
  for _lib in libudev.so.1 libselinux.so.1 libz.so.1 libgdk-x11-2.0.so.0; do
    _path="$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -maxdepth 1 -name "$_lib" -print -quit 2>/dev/null)"
    [[ -n "$_path" ]] && _preload="${_preload:+$_preload }$_path"
  done
  FPGA_LD_PRELOAD="$_preload"
fi

# Prefer the per-user systemd manager: the tool then runs in its own cgroup,
# independent of this orbctl-run shell, so it reliably survives once we exit.
# A plain setsid child launched from orbctl run is flaky (the GUI sometimes
# never materializes); KillMode=process keeps the GUI alive after the tool's
# own launcher wrapper forks the IDE and exits. LD_PRELOAD set above is passed
# through so the GUI and its launch_runs child processes all inherit it.
launched=0
if command -v systemd-run >/dev/null 2>&1; then
  unit="fpga-${tool}-$(date +%s)-$$"
  sd_args=(--user -p KillMode=process --collect --unit="$unit"
    --setenv=DISPLAY="$DISPLAY"
    --setenv=XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
    --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
    --setenv=PATH="$PATH"
    --working-directory="$workdir")
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && sd_args+=(--setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS")
  [[ -n "${FPGA_LD_PRELOAD:-}" ]] && sd_args+=(--setenv=LD_PRELOAD="$FPGA_LD_PRELOAD")
  if systemd-run "${sd_args[@]}" "${cmd[@]}" >>"$logfile" 2>&1; then
    echo "$tool started as user service $unit"
    launched=1
  else
    echo "systemd-run launch failed; falling back to setsid." >&2
  fi
fi

if (( ! launched )); then
  [[ -n "${FPGA_LD_PRELOAD:-}" ]] && export LD_PRELOAD="${FPGA_LD_PRELOAD}${LD_PRELOAD:+ ${LD_PRELOAD}}"
  setsid "${cmd[@]}" > "$logfile" 2>&1 < /dev/null &
  disown 2>/dev/null || true
  echo "$tool launched detached (pid $!) in $workdir"
fi
GUESTEOF

  orb_machine bash -lc 'cat > "$HOME/bin/start-vivado-gui"; chmod +x "$HOME/bin/start-vivado-gui"' <<'GUESTEOF'
#!/usr/bin/env bash
exec "$HOME/bin/fpga-launch-gui" vivado "${1:-}"
GUESTEOF

  orb_machine bash -lc 'cat > "$HOME/bin/start-vitis-gui"; chmod +x "$HOME/bin/start-vitis-gui"' <<'GUESTEOF'
#!/usr/bin/env bash
exec "$HOME/bin/fpga-launch-gui" vitis "${1:-}"
GUESTEOF

  orb_machine bash -lc 'cat > "$HOME/bin/fpga-tool-shim"; chmod +x "$HOME/bin/fpga-tool-shim"; for t in vivado vitis xsct vitis_hls; do ln -sf fpga-tool-shim "$HOME/bin/$t"; done' <<'GUESTEOF'
#!/usr/bin/env bash
# Tool shim generated by fpga-devbox. Invoked via symlinks named
# vivado/vitis/xsct/vitis_hls. Preloads the real system libudev (plus
# libselinux/libz/libgdk) so Vivado FlexLM dlopen(RTLD_DEEPBIND) does not
# segfault in libudev under Rosetta x86, then execs the real tool. Works for
# any caller (interactive bash, tclsh exec, make, ...), not just bash.
set -u
tool="$(basename "$0")"

# Find the real tool on PATH with ~/bin (where this shim lives) removed, so we
# never re-invoke ourselves.
IFS=':' read -r -a _dirs <<< "${PATH:-}"
_clean=""
for _d in "${_dirs[@]}"; do
  [[ -n "$_d" ]] || continue
  [[ "$_d" == "$HOME/bin" ]] && continue
  _clean="${_clean:+$_clean:}$_d"
done
real="$(PATH="$_clean" command -v "$tool" 2>/dev/null || true)"
if [[ -z "$real" ]]; then
  echo "$tool: real binary not found on PATH (only the ~/bin shim is present)." >&2
  echo "Source ~/.xilinx-settings.sh first so the Xilinx tools are on PATH." >&2
  exit 127
fi

# Resolve the preload libs once if not already set (Ubuntu 24.04 layout).
if [[ -z "${FPGA_LD_PRELOAD:-}" ]]; then
  FPGA_LD_PRELOAD=""
  for _lib in libudev.so.1 libselinux.so.1 libz.so.1 libgdk-x11-2.0.so.0; do
    _f="$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -maxdepth 1 -name "$_lib" -print -quit 2>/dev/null)"
    [[ -n "$_f" ]] && FPGA_LD_PRELOAD="${FPGA_LD_PRELOAD:+$FPGA_LD_PRELOAD }$_f"
  done
fi
[[ -n "$FPGA_LD_PRELOAD" ]] && export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD }$FPGA_LD_PRELOAD"
exec "$real" "$@"
GUESTEOF

  orb_machine bash -lc 'cat > "$HOME/bin/fpga-usb-setup"; chmod +x "$HOME/bin/fpga-usb-setup"' <<'GUESTEOF'
#!/usr/bin/env bash
# fpga-usb-setup: prepare the Digilent FT2232H (0403:6010) for Vivado JTAG in
# OrbStack passthrough/dedicated USB mode. Idempotent and best-effort.
# Generated by fpga-devbox; safe to regenerate.
#
# The board is a single FT2232H: USB interface 0 is JTAG (claimed by Vivado
# hw_server via libusb), interface 1 is the UART (kernel ftdi_sio -> ttyUSB).
# In passthrough mode the ftdi_sio driver binds inconsistently: sometimes only
# interface 1, sometimes BOTH interfaces. When interface 0 is bound, libusb
# cannot claim it and JTAG is blocked. This helper unbinds interface 0 so JTAG
# works, makes sure interface 1 is bound, and chmods its ttyUSB node so the
# UART is user-accessible. In forwarded (orb serial) mode there is no raw USB
# device, so this prints a hint and exits 0.
#
# OrbStack does not drive systemd-udevd on re-enumeration, so we touch sysfs
# bind/unbind directly instead of relying on udev rules. Never run udevadm
# settle (it hangs) and never run a full usb add trigger (the Xilinx rule would
# unbind ftdi_sio from BOTH interfaces and kill the UART).
set -uo pipefail

drv="/sys/bus/usb/drivers/ftdi_sio"
devs_root="/sys/bus/usb/devices"

# Enumerate FT2232H (0403:6010) USB devices by scanning sysfs. A device dir
# looks like "1-1" (no colon); interface dirs contain a colon (e.g. 1-1:1.0).
mapfile -t _ids < <(
  for D in "$devs_root"/*; do
    [[ -d "$D" ]] || continue
    base="$(basename "$D")"
    case "$base" in *:*) continue ;; esac
    [[ -r "$D/idVendor" && -r "$D/idProduct" ]] || continue
    [[ "$(cat "$D/idVendor" 2>/dev/null)" == "0403" ]] || continue
    [[ "$(cat "$D/idProduct" 2>/dev/null)" == "6010" ]] || continue
    echo "$base"
  done
)

if (( ${#_ids[@]} == 0 )); then
  echo "No FTDI FT2232H (0403:6010) found in passthrough mode."
  echo "If the board is in OrbStack forwarded (orb serial) mode there is no raw"
  echo "USB device, so JTAG is not possible; switch OrbStack to dedicated/"
  echo "passthrough for Vivado JTAG. The UART still works in forwarded mode via"
  echo "fpga-uart."
  exit 0
fi

for id in "${_ids[@]}"; do
  echo "FTDI FT2232H at USB device $id:"

  # Interface 0 = JTAG. If ftdi_sio is bound to it, unbind so libusb can claim it.
  if [[ -e "$drv/$id:1.0" ]]; then
    echo -n "$id:1.0" | sudo tee "$drv/unbind" >/dev/null 2>&1 || true
  fi
  if [[ -e "$drv/$id:1.0" ]]; then
    jtag_state="interface 0 still bound to ftdi_sio (JTAG may be blocked)"
  else
    jtag_state="interface 0 free (JTAG ready)"
  fi

  # Interface 1 = UART. Make sure ftdi_sio is bound so a ttyUSB node exists.
  if [[ ! -e "$drv/$id:1.1" && -e "$devs_root/$id:1.1" ]]; then
    echo -n "$id:1.1" | sudo tee "$drv/bind" >/dev/null 2>&1 || true
  fi

  # Locate the UART ttyUSB node and make it user-accessible via chmod.
  uart_node=""
  for T in "$devs_root/$id:1.1"/ttyUSB*; do
    [[ -e "$T" ]] || continue
    uart_node="/dev/$(basename "$T")"
    break
  done
  if [[ -z "$uart_node" ]]; then
    for T in /dev/ttyUSB*; do
      [[ -e "$T" ]] || continue
      uart_node="$T"
      break
    done
  fi
  if [[ -n "$uart_node" ]]; then
    sudo chmod 666 "$uart_node" 2>/dev/null || true
    uart_state="$uart_node ($(stat -c '%A' "$uart_node" 2>/dev/null || echo perms?))"
  else
    uart_state="no UART ttyUSB node found"
  fi

  echo "  JTAG: $jtag_state"
  echo "  UART: $uart_state"
done
GUESTEOF

  orb_machine bash -lc 'cat > "$HOME/bin/fpga-uart"; chmod +x "$HOME/bin/fpga-uart"' <<'GUESTEOF'
#!/usr/bin/env bash
# fpga-uart: open the Digilent FT2232H UART in either OrbStack USB mode.
# Generated by fpga-devbox; safe to regenerate.
#
# The board is a single FT2232H (0403:6010): USB interface 0 is JTAG (no tty),
# interface 1 is the UART. OrbStack exposes this device two ways:
#   PASSTHROUGH/DEDICATED: a raw USB device bound by the kernel ftdi_sio driver;
#     the UART appears as /dev/ttyUSB<N> (N depends on enumeration order).
#   FORWARDED (orb serial): a serial bridge only; the UART appears as
#     /dev/cu.usbserial-<SERIAL>1 (and /dev/tty.usbserial-<SERIAL>1), where the
#     trailing digit is the USB interface index (1 = UART). No raw USB, no JTAG.
#
# OrbStack does not drive systemd-udevd, so /dev/serial/by-id is usually absent
# and udev rules do not auto-apply; perms on a ttyUSB node are fixed with a
# direct chmod (the bridge cu/tty nodes are already dialout 0660 accessible).
# Never run udevadm settle (it hangs) and never run a full usb add trigger.
set -uo pipefail

dev="${1:-}"
baud="${2:-115200}"

if [[ -z "$dev" ]]; then
  # (b) PASSTHROUGH: prefer the stable Digilent UART by-id symlink (interface 1,
  # usually absent under OrbStack), then any -if01-port0 by-id link.
  mapfile -t _byid < <(ls -1 /dev/serial/by-id/*Digilent*-if01-port0 2>/dev/null || true)
  if (( ${#_byid[@]} == 0 )); then
    mapfile -t _byid < <(ls -1 /dev/serial/by-id/*-if01-port0 2>/dev/null || true)
  fi
  (( ${#_byid[@]} > 0 )) && dev="${_byid[0]}"

  # (b) PASSTHROUGH fallback: the highest-numbered raw ttyUSB node.
  if [[ -z "$dev" ]]; then
    mapfile -t _tty < <(ls -1 /dev/ttyUSB* 2>/dev/null | sort -V || true)
    (( ${#_tty[@]} > 0 )) && dev="${_tty[-1]}"
  fi

  # (c) FORWARDED (orb serial): the interface-1 serial-bridge node. Prefer the
  # cu.* node over tty.*; the trailing digit is the USB interface index, so the
  # last entry when sorted is the UART (interface 1).
  if [[ -z "$dev" ]]; then
    mapfile -t _br < <(ls -1 /dev/cu.usbserial-* 2>/dev/null | sort -V || true)
    if (( ${#_br[@]} == 0 )); then
      mapfile -t _br < <(ls -1 /dev/tty.usbserial-* 2>/dev/null | sort -V || true)
    fi
    (( ${#_br[@]} > 0 )) && dev="${_br[-1]}"
  fi

  # (d) Nothing found anywhere.
  if [[ -z "$dev" ]]; then
    echo "No UART found." >&2
    echo "Make sure the board is connected." >&2
    echo "If you only need the UART, OrbStack forwarded (orb serial) mode is fine." >&2
    echo "If you also need Vivado JTAG, use passthrough/dedicated mode and run fpga-usb-setup first." >&2
    echo "Also close Vivado Hardware Manager (it holds the whole FT2232H chip), then retry." >&2
    exit 1
  fi
fi

# Resolve to the real node. Only a raw ttyUSB node may need a perms fix (OrbStack
# does not drive udev); the cu.*/tty.* bridge nodes are already dialout 0660.
real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
case "$real" in
  /dev/ttyUSB*) sudo chmod 666 "$real" 2>/dev/null || true ;;
esac

echo "Opening $dev (-> $real) at ${baud} baud (tio auto-reconnects; press Ctrl-t q to quit)."
exec tio -b "$baud" "$dev"
GUESTEOF

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
