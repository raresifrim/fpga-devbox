#!/usr/bin/env bash
set -euo pipefail

INSTALLER_PATH="${1:-}"
VITIS_VER="${VITIS_VER:-2025.2}"
VITIS_EDITION="${VITIS_EDITION:-Vitis Unified Software Platform}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
INSTALL_CONFIG="${INSTALL_CONFIG:-}"
XRDP_PASSWORD="${XRDP_PASSWORD:-}"
AUTH_TOKEN_FILE="${XILINX_AUTH_TOKEN_FILE:-$HOME/.Xilinx/wi_authentication_key}"
FORCE_AUTH_TOKEN_GEN="${FORCE_AUTH_TOKEN_GEN:-0}"
SKIP_AUTH_TOKEN_GEN="${SKIP_AUTH_TOKEN_GEN:-0}"
OSS_CAD_SUITE_DIR="${OSS_CAD_SUITE_DIR:-$HOME/oss-cad-suite}"
OSS_CAD_SUITE_DATE="${OSS_CAD_SUITE_DATE:-}"
SKIP_OSS_CAD_SUITE="${SKIP_OSS_CAD_SUITE:-0}"

module_name_from_entry() {
  local entry="$1"
  echo "${entry%:*}"
}

is_valid_module_entry() {
  local entry="$1"
  local valid_modules_file="$2"
  local name
  name="$(module_name_from_entry "$entry")"
  grep -Fxq "$name" "$valid_modules_file"
}

reset_install_config_files() {
  rm -f \
    "$HOME/install_config.txt" \
    "$HOME/.Xilinx/install_config.txt" \
    "$HOME/.xilinx-install-config.compiled.txt"
}

collect_install_config_modules() {
  local src="$1"
  local -n _modules_out="$2"
  local line modules_line part

  if grep -E '^Modules=.*,' "$src" >/dev/null 2>&1; then
    modules_line="$(grep '^Modules=' "$src" | head -n1 | sed 's/^Modules=//')"
    local IFS=,
    read -ra parts <<< "$modules_line"
    for part in "${parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ "$part" =~ :[01]$ ]] && _modules_out+=("$part")
    done
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ :[01]$ ]] && _modules_out+=("$line")
  done < "$src"
}

prepare_install_config() {
  local src="$1"
  local dst="$2"
  local install_root="$3"
  local valid_modules_file="$4"
  local -a header=()
  local -a modules=()
  local -a footer=()
  local -a filtered_modules=()
  local line entry

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    case "$line" in
      Edition=*|Product=*|Destination=*)
        header+=("$line")
        ;;
      InstallOptions=*|CreateProgramGroupShortcuts=*|ProgramGroupFolder=*|CreateShortcutsForAllUsers=*|CreateDesktopShortcuts=*|CreateFileAssociation=*|EnableDiskUsageOptimization=*)
        footer+=("$line")
        ;;
      Modules=*)
        ;;
      *:0|*:1)
        modules+=("$line")
        ;;
      *)
        [[ "$line" =~ ^#### ]] && header+=("$line")
        ;;
    esac
  done < "$src"

  if ((${#modules[@]} == 0)); then
    collect_install_config_modules "$src" modules
  fi

  if ((${#modules[@]} == 0)); then
    echo "Install config has no module entries: $src" >&2
    exit 1
  fi

  for entry in "${modules[@]}"; do
    if is_valid_module_entry "$entry" "$valid_modules_file"; then
      filtered_modules+=("$entry")
    else
      echo "Skipping unsupported module for this installer: $(module_name_from_entry "$entry")" >&2
    fi
  done

  if ((${#filtered_modules[@]} == 0)); then
    echo "No valid module entries remain after filtering: $src" >&2
    exit 1
  fi

  {
    for line in "${header[@]}"; do
      if [[ "$line" == Destination=* ]]; then
        echo "Destination=$install_root"
      else
        echo "$line"
      fi
    done
    if ! printf '%s\n' "${header[@]}" | grep -q '^Destination='; then
      echo "Destination=$install_root"
    fi
    printf 'Modules='
    local i
    for i in "${!filtered_modules[@]}"; do
      ((i)) && printf ','
      printf '%s' "${filtered_modules[$i]}"
    done
    printf '\n'
    for line in "${footer[@]}"; do
      echo "$line"
    done
  } > "$dst"
}

generate_valid_modules_list() {
  local setup_bin="$1"
  local output_file="$2"
  local setup_dir
  setup_dir="$(dirname "$setup_bin")"
  local config_seed="$setup_dir/configgen_seed.txt"
  local config_source="$HOME/.Xilinx/install_config.txt"

  mkdir -p "$(dirname "$output_file")"
  touch "$config_seed"
  if ! (cd "$setup_dir" && printf '1\n' | ./xsetup -b ConfigGen -c "$config_seed" >/dev/null 2>&1); then
    echo "Failed to query valid installer modules from xsetup ConfigGen." >&2
    exit 1
  fi

  if [[ ! -f "$config_source" ]]; then
    echo "ConfigGen did not produce $config_source" >&2
    exit 1
  fi

  python3 - "$config_source" "$output_file" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
match = re.search(r"^Modules=(.*)$", text, re.M)
if not match:
    raise SystemExit("No Modules= line found in ConfigGen output")
with open(sys.argv[2], "w") as out:
    for item in match.group(1).split(","):
        out.write(item.rsplit(":", 1)[0] + "\n")
PY
}

auth_token_present() {
  [[ -s "$AUTH_TOKEN_FILE" ]]
}

installer_needs_auth_token() {
  case "$INSTALLER_PATH" in
    *.bin) return 0 ;;
    *) return 1 ;;
  esac
}

generate_amd_auth_token_expect() {
  local setup_bin="$1"
  local email="$2"
  local password="$3"
  local setup_dir
  setup_dir="$(dirname "$setup_bin")"

  if ! command -v expect >/dev/null 2>&1; then
    echo "expect is required for non-interactive AuthTokenGen." >&2
    echo "Install it with: sudo apt-get install -y expect" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$AUTH_TOKEN_FILE")"
  (
    cd "$setup_dir"
    EXPECT_BIN="./xsetup" EXPECT_EMAIL="$email" EXPECT_PASSWORD="$password" expect <<'EXPECT'
set timeout 300
spawn $env(EXPECT_BIN) -b AuthTokenGen
expect {
  -re {E-mail Address:} {
    send "$env(EXPECT_EMAIL)\r"
    exp_continue
  }
  -re {Password:} {
    send "$env(EXPECT_PASSWORD)\r"
    exp_continue
  }
  -re {Saved authentication token file successfully} {
    exit 0
  }
  eof {
    exit 1
  }
  timeout {
    exit 1
  }
}
EXPECT
  )
}

generate_amd_auth_token_interactive() {
  local setup_bin="$1"
  local setup_dir
  setup_dir="$(dirname "$setup_bin")"
  mkdir -p "$(dirname "$AUTH_TOKEN_FILE")"
  (cd "$setup_dir" && ./xsetup -b AuthTokenGen)
}

ensure_amd_auth_token() {
  local setup_bin="$1"

  if [[ "$SKIP_AUTH_TOKEN_GEN" == 1 ]]; then
    echo "Skipping AMD auth token check (SKIP_AUTH_TOKEN_GEN=1)."
    return 0
  fi

  if ! installer_needs_auth_token; then
    echo "Offline installer format detected; AMD auth token not required."
    return 0
  fi

  if [[ "$FORCE_AUTH_TOKEN_GEN" != 1 ]] && auth_token_present; then
    echo "Using existing AMD auth token: $AUTH_TOKEN_FILE"
    return 0
  fi

  echo "The SDI/web installer downloads payloads during install and needs an AMD auth token first."
  echo "Token path: $AUTH_TOKEN_FILE (valid about 7 days)."

  if [[ -n "${XILINX_AMD_EMAIL:-}" && -n "${XILINX_AMD_PASSWORD:-}" ]]; then
    echo "Generating auth token for $XILINX_AMD_EMAIL..."
    generate_amd_auth_token_expect "$setup_bin" "$XILINX_AMD_EMAIL" "$XILINX_AMD_PASSWORD"
  elif [[ -t 0 ]]; then
    echo "Run AuthTokenGen interactively (AMD account email + password)."
    generate_amd_auth_token_interactive "$setup_bin"
  else
    cat <<MSG >&2
No AMD auth token found at $AUTH_TOKEN_FILE.

The SDI .bin is a web-installer client: it downloads Vivado/Vitis payloads during
batch install. Generate a token once (internet + AMD account), then rerun setup.

Interactive (recommended):

  orbctl run -m <machine>
  /path/to/setup_fpga_devbox_machine.sh "/path/to/installer.bin"

The setup script extracts the installer, finds the actual xsetup path, runs
AuthTokenGen, and then continues the batch install.

Non-interactive (token valid ~7 days; password appears in shell history):

  orbctl run -m <machine> bash -lc 'XILINX_AMD_EMAIL=you@example.com XILINX_AMD_PASSWORD=secret /path/to/setup_fpga_devbox_machine.sh "/path/to/installer.bin"'

If you generated a token on another machine, copy ~/.Xilinx/wi_authentication_key into
the VM. For a full offline .tar.gz installer, set SKIP_AUTH_TOKEN_GEN=1 instead.

MSG
    exit 1
  fi

  if ! auth_token_present; then
    echo "AuthTokenGen did not create $AUTH_TOKEN_FILE" >&2
    exit 1
  fi
  echo "AMD auth token ready: $AUTH_TOKEN_FILE"
}

install_oss_cad_suite() {
  if [[ "$SKIP_OSS_CAD_SUITE" == 1 ]]; then
    echo "Skipping OSS CAD Suite install (SKIP_OSS_CAD_SUITE=1)."
    return 0
  fi

  echo "Installing OSS CAD Suite (yosys, nextpnr, verilator, iverilog, gtkwave, ...)"

  local download_url=""
  if [[ -n "$OSS_CAD_SUITE_DATE" ]]; then
    local tag="$OSS_CAD_SUITE_DATE"
    local compact="${OSS_CAD_SUITE_DATE//-/}"
    download_url="https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${tag}/oss-cad-suite-linux-x64-${compact}.tgz"
  else
    download_url="$(curl -fsSL https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest | python3 -c '
import json, sys
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if "linux-x64" in name and name.endswith(".tgz"):
        print(asset["browser_download_url"])
        break
')"
  fi

  if [[ -z "$download_url" ]]; then
    echo "Could not determine OSS CAD Suite linux-x64 download URL." >&2
    exit 1
  fi

  echo "Downloading $download_url"
  local tmp_archive staging
  tmp_archive="$(mktemp /tmp/oss-cad-suite.XXXXXX.tgz)"
  curl -fL --retry 3 -o "$tmp_archive" "$download_url"

  staging="$(mktemp -d /tmp/oss-cad-suite-stage.XXXXXX)"
  tar -xzf "$tmp_archive" -C "$staging"
  if [[ ! -d "$staging/oss-cad-suite" ]]; then
    echo "Unexpected OSS CAD Suite archive layout (no top-level oss-cad-suite/)." >&2
    rm -rf "$staging" "$tmp_archive"
    exit 1
  fi

  rm -rf "$OSS_CAD_SUITE_DIR"
  mkdir -p "$(dirname "$OSS_CAD_SUITE_DIR")"
  mv "$staging/oss-cad-suite" "$OSS_CAD_SUITE_DIR"
  rm -rf "$staging" "$tmp_archive"

  if [[ ! -f "$OSS_CAD_SUITE_DIR/environment" ]]; then
    echo "OSS CAD Suite environment not found at $OSS_CAD_SUITE_DIR after extraction." >&2
    exit 1
  fi

  if ! grep -q 'oss-cad-suite/environment' "$HOME/.bashrc" 2>/dev/null; then
    echo "source \"$OSS_CAD_SUITE_DIR/environment\" 2>/dev/null || true" >> "$HOME/.bashrc"
  fi

  echo "OSS CAD Suite installed to $OSS_CAD_SUITE_DIR and sourced in ~/.bashrc"
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") /absolute/path/to/Xilinx_Unified_2025.2_*.bin|*.tar.gz
  $(basename "$0") /absolute/path/to/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_*.bin

The path must be absolute on macOS. OrbStack exposes it inside Linux at the same
location (for example /Users/you/Downloads/installer.bin), and this script copies
it into the VM before installation.

Environment overrides:
  VITIS_VER=2025.2
  VITIS_EDITION="Vitis Unified Software Platform"
  INSTALL_ROOT=/tools/Xilinx
  INSTALL_CONFIG=/path/to/config/vitis_unified_2025.2.install_config
  XRDP_PASSWORD=your-rdp-password # optional; sets the Linux user's RDP password
  XILINX_AMD_EMAIL=you@example.com
  XILINX_AMD_PASSWORD=secret   # optional; used with expect for AuthTokenGen
  SKIP_AUTH_TOKEN_GEN=1          # for full offline .tar.gz installers
  FORCE_AUTH_TOKEN_GEN=1         # regenerate token even if one exists
  OSS_CAD_SUITE_DIR=\$HOME/oss-cad-suite # where OSS CAD Suite is installed
  OSS_CAD_SUITE_DATE=YYYY-MM-DD  # pin a specific OSS CAD Suite release
  SKIP_OSS_CAD_SUITE=1           # skip installing OSS CAD Suite
USAGE
}

[[ -n "$INSTALLER_PATH" ]] || { usage; exit 1; }
[[ -e "$INSTALLER_PATH" ]] || { echo "Installer not found in machine: $INSTALLER_PATH" >&2; exit 1; }

LINUX_ARCH="$(uname -m)"
if [[ "$LINUX_ARCH" != "x86_64" ]]; then
  cat <<MSG >&2
This machine reports architecture '$LINUX_ARCH', but Vivado/Vitis require x86_64 (amd64).

On Apple Silicon, recreate the OrbStack machine with Rosetta-backed x86 emulation:
  orbctl delete <machine-name>
  ./setup_fpga_devbox_host.sh /absolute/path/to/installer.bin
MSG
  exit 1
fi

SOURCE_INSTALLER="$INSTALLER_PATH"

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
  xfce4 xfce4-goodies xrdp xorgxrdp dbus-x11 x11-xserver-utils \
  build-essential git wget curl unzip file p7zip-full \
  libglib2.0-0 libsm6 libxi6 libxrender1 libxrandr2 \
  libfreetype6 libfontconfig1 libxext6 libxtst6 libx11-6 \
  libgtk2.0-0 libxcb1 libxcb-util1 \
  libncurses6 libtinfo6 python3 python3-pip locales lsb-release usbutils \
  expect tio

sudo locale-gen en_US.UTF-8

# Digilent boards expose JTAG + UART on a single FT2232H (0403:6010): interface 0
# is JTAG (used by Vivado via libusb), interface 1 is the UART. ftdi_sio binds
# interface 1 to /dev/ttyUSBn, but OrbStack creates it root:root, so give it the
# dialout group + a stable /dev/digilent-uart symlink that survives the USB
# re-enumeration Vivado triggers on every program. Use 'tio /dev/digilent-uart'
# (it auto-reconnects) and reopen / close Hardware Manager after programming.
sudo tee /etc/udev/rules.d/99-digilent-ftdi.rules >/dev/null <<'UDEV'
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", ATTRS{bInterfaceNumber}=="01", GROUP="dialout", MODE="0660", SYMLINK+="digilent-uart"
UDEV
sudo udevadm control --reload 2>/dev/null || true
sudo udevadm trigger --subsystem-match=tty --action=add 2>/dev/null || true

echo startxfce4 > "$HOME/.xsession"
chmod 644 "$HOME/.xsession"

if ! grep -q 'unset DBUS_SESSION_BUS_ADDRESS' /etc/xrdp/startwm.sh; then
  sudo cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
  sudo awk '
    BEGIN{done=0}
    {
      print
      if (!done && /fi$/) {
        print "unset DBUS_SESSION_BUS_ADDRESS"
        print "unset XDG_RUNTIME_DIR"
        done=1
      }
    }
  ' /etc/xrdp/startwm.sh.bak | sudo tee /etc/xrdp/startwm.sh >/dev/null
  sudo chmod 755 /etc/xrdp/startwm.sh
fi

sudo adduser xrdp ssl-cert || true

# OrbStack/LXC cannot verify forked PID files ("Inappropriate ioctl for device"),
# which makes the stock Type=forking units time out after 90s. Run in foreground.
sudo mkdir -p /etc/systemd/system/xrdp-sesman.service.d /etc/systemd/system/xrdp.service.d
sudo tee /etc/systemd/system/xrdp-sesman.service.d/orbstack.conf >/dev/null <<'EOF'
[Unit]
BindsTo=
StopWhenUnneeded=

[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/usr/sbin/xrdp-sesman -n
EOF
sudo tee /etc/systemd/system/xrdp.service.d/orbstack.conf >/dev/null <<'EOF'
[Unit]
Requires=

[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/usr/sbin/xrdp -n
EOF
sudo systemctl daemon-reload

sudo mkdir -p /var/log
sudo touch /var/log/xrdp.log /var/log/xrdp-sesman.log
sudo chown xrdp:adm /var/log/xrdp.log
sudo chown root:adm /var/log/xrdp-sesman.log
sudo chmod 640 /var/log/xrdp.log /var/log/xrdp-sesman.log

sudo systemctl enable xrdp-sesman xrdp
sudo systemctl restart xrdp-sesman
sudo systemctl restart xrdp

if ! systemctl is-active --quiet xrdp-sesman || ! systemctl is-active --quiet xrdp; then
  echo "XRDP failed to start. Check logs with:" >&2
  echo "  journalctl -u xrdp-sesman -u xrdp --no-pager" >&2
  exit 1
fi

if [[ -n "$XRDP_PASSWORD" ]]; then
  echo "$USER:$XRDP_PASSWORD" | sudo chpasswd
  echo "Set RDP password for Linux user: $USER"
fi

sudo mkdir -p "$INSTALL_ROOT"
sudo chown -R "$USER":"$USER" "$INSTALL_ROOT"

WORKDIR="$HOME/xilinx-installer"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

INSTALLER_BASENAME="$(basename "$SOURCE_INSTALLER")"
INSTALLER_PATH="$WORKDIR/$INSTALLER_BASENAME"
if [[ "$SOURCE_INSTALLER" != "$INSTALLER_PATH" ]]; then
  echo "Copying installer from $SOURCE_INSTALLER to $INSTALLER_PATH"
  cp -f "$SOURCE_INSTALLER" "$INSTALLER_PATH"
fi
chmod +r "$INSTALLER_PATH"

locate_xsetup() {
  local root="$1"
  if [[ -x "$root/xsetup" ]]; then
    echo "$root/xsetup"
    return 0
  fi
  find "$root" -maxdepth 4 -type f -name xsetup -perm -111 2>/dev/null | head -n1
}

EXTRACT_DIR="$WORKDIR/extracted"
mkdir -p "$EXTRACT_DIR"

case "$INSTALLER_PATH" in
  *.tar.gz)
    echo "Extracting $(basename "$INSTALLER_PATH")..."
    tar -xzf "$INSTALLER_PATH" -C "$EXTRACT_DIR"
    ;;
  *.bin)
    echo "Extracting installer payload from $(basename "$INSTALLER_PATH")..."
    chmod +x "$INSTALLER_PATH"
    "$INSTALLER_PATH" --keep --noexec --target "$EXTRACT_DIR"
    ;;
  *)
    echo "Unsupported installer format: $INSTALLER_PATH" >&2
    exit 1
    ;;
esac

SETUP_BIN="$(locate_xsetup "$EXTRACT_DIR")"
if [[ -z "$SETUP_BIN" ]]; then
  echo "Could not locate xsetup after extracting the installer." >&2
  echo "Contents of $EXTRACT_DIR:" >&2
  ls -la "$EXTRACT_DIR" >&2 || true
  exit 1
fi

VALID_MODULES_FILE="$WORKDIR/valid_modules.txt"
generate_valid_modules_list "$SETUP_BIN" "$VALID_MODULES_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_CONFIG="$SCRIPT_DIR/config/vitis_unified_2025.2.install_config"
if [[ -z "$INSTALL_CONFIG" && -f "$DEFAULT_INSTALL_CONFIG" ]]; then
  INSTALL_CONFIG="$DEFAULT_INSTALL_CONFIG"
  echo "Using default install config: $INSTALL_CONFIG"
fi

install_oss_cad_suite

ensure_amd_auth_token "$SETUP_BIN"

echo "Running batch install with $SETUP_BIN"
if [[ -n "$INSTALL_CONFIG" ]]; then
  [[ -f "$INSTALL_CONFIG" ]] || { echo "Install config not found: $INSTALL_CONFIG" >&2; exit 1; }
  reset_install_config_files
  ACTIVE_INSTALL_CONFIG="$HOME/install_config.txt"
  cp -f "$INSTALL_CONFIG" "$ACTIVE_INSTALL_CONFIG"
  chmod 644 "$ACTIVE_INSTALL_CONFIG"
  COMPILED_INSTALL_CONFIG="$HOME/.xilinx-install-config.compiled.txt"
  prepare_install_config "$ACTIVE_INSTALL_CONFIG" "$COMPILED_INSTALL_CONFIG" "$INSTALL_ROOT" "$VALID_MODULES_FILE"
  echo "Using install config: $ACTIVE_INSTALL_CONFIG (from $INSTALL_CONFIG, compiled to $COMPILED_INSTALL_CONFIG)"
  "$SETUP_BIN" --agree XilinxEULA,3rdPartyEULA --batch Install --config "$COMPILED_INSTALL_CONFIG"
else
  echo "Using AMD default modules for edition: $VITIS_EDITION"
  echo "To customize devices/tools, run '$SETUP_BIN -b ConfigGen' and rerun with INSTALL_CONFIG set."
  "$SETUP_BIN" --agree XilinxEULA,3rdPartyEULA --batch Install \
    --edition "$VITIS_EDITION" \
    --location "$INSTALL_ROOT"
fi

# Disable WebTalk usage-data collection. Besides the privacy aspect, WebTalk
# fingerprints the host via FlexLM + libudev (udev_enumerate_scan_devices),
# which segfaults under OrbStack/Rosetta x86 emulation at the end of synth/impl.
# config_webtalk is AMD's documented install-preference toggle (UG973); placing
# it in the tool init scripts runs it on every launch, including the headless
# vivado child processes spawned by launch_runs, so the transmit path is never
# reached and the install-level preference is written when the tree is writable.
for webtalk_init in \
  "$HOME/.Xilinx/Vivado/Vivado_init.tcl" \
  "$HOME/.Xilinx/Vitis/Vitis_init.tcl"; do
  mkdir -p "$(dirname "$webtalk_init")"
  if ! grep -qs 'config_webtalk -install off' "$webtalk_init"; then
    printf '%s\n' \
      '# Added by fpga-devbox: disable WebTalk usage statistics.' \
      'catch {config_webtalk -install off}' >> "$webtalk_init"
  fi
done
echo "WebTalk disabled via ~/.Xilinx/Vivado/Vivado_init.tcl (and Vitis_init.tcl)."

mkdir -p "$HOME/bin"
cat > "$HOME/.xilinx-settings.sh" <<SH
#!/usr/bin/env bash
# Source all available Xilinx 2025.2 settings scripts. AMD installer layouts vary
# between web/SDI and full offline packages, and Vitis workflows can need both.
found=0
had_nounset=0
case "\$-" in
  *u*) had_nounset=1; set +u ;;
esac
for settings in \\
  "$INSTALL_ROOT/$VITIS_VER/Vivado/settings64.sh" \\
  "$INSTALL_ROOT/Vivado/$VITIS_VER/settings64.sh" \\
  "$INSTALL_ROOT/$VITIS_VER/Vitis/settings64.sh" \\
  "$INSTALL_ROOT/Vitis/$VITIS_VER/settings64.sh"; do
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

if ! grep -q 'source "$HOME/.xilinx-settings.sh"' "$HOME/.bashrc"; then
  echo 'source "$HOME/.xilinx-settings.sh" 2>/dev/null || true' >> "$HOME/.bashrc"
fi

cat > "$HOME/bin/fpga-launch-gui" <<'LAUNCH'
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
LAUNCH
chmod +x "$HOME/bin/fpga-launch-gui"

cat > "$HOME/bin/start-vivado-gui" <<'LAUNCH'
#!/usr/bin/env bash
exec "$HOME/bin/fpga-launch-gui" vivado "${1:-}"
LAUNCH
chmod +x "$HOME/bin/start-vivado-gui"

cat > "$HOME/bin/start-vitis-gui" <<'LAUNCH'
#!/usr/bin/env bash
exec "$HOME/bin/fpga-launch-gui" vitis "${1:-}"
LAUNCH
chmod +x "$HOME/bin/start-vitis-gui"

cat > "$HOME/bin/fpga-tool-shim" <<'LAUNCH'
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
LAUNCH
chmod +x "$HOME/bin/fpga-tool-shim"
for _t in vivado vitis xsct vitis_hls; do ln -sf fpga-tool-shim "$HOME/bin/$_t"; done

cat > "$HOME/bin/fpga-usb-setup" <<'USBSETUP'
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
USBSETUP
chmod +x "$HOME/bin/fpga-usb-setup"

cat > "$HOME/bin/fpga-uart" <<'UART'
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
UART
chmod +x "$HOME/bin/fpga-uart"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

cat <<MSG
Machine setup complete.

RDP login:
  username: $USER
  password: the Linux password for $USER

If you did not set XRDP_PASSWORD during setup, set or reset the password with:
  sudo passwd "$USER"

Verify services:
  systemctl status xrdp --no-pager

Then from macOS, run your fpga_devbox launcher.
MSG
