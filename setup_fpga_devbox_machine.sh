#!/usr/bin/env bash
set -euo pipefail

INSTALLER_PATH="${1:-}"
VITIS_VER="${VITIS_VER:-2025.2}"
VITIS_EDITION="${VITIS_EDITION:-Vitis Unified Software Platform}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
INSTALL_CONFIG="${INSTALL_CONFIG:-}"
AUTH_TOKEN_FILE="${XILINX_AUTH_TOKEN_FILE:-$HOME/.Xilinx/wi_authentication_key}"
FORCE_AUTH_TOKEN_GEN="${FORCE_AUTH_TOKEN_GEN:-0}"
SKIP_AUTH_TOKEN_GEN="${SKIP_AUTH_TOKEN_GEN:-0}"

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
  XILINX_AMD_EMAIL=you@example.com
  XILINX_AMD_PASSWORD=secret   # optional; used with expect for AuthTokenGen
  SKIP_AUTH_TOKEN_GEN=1          # for full offline .tar.gz installers
  FORCE_AUTH_TOKEN_GEN=1         # regenerate token even if one exists
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
  verilator iverilog expect

sudo locale-gen en_US.UTF-8

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

if ! grep -q "$INSTALL_ROOT/Vitis/$VITIS_VER/settings64.sh" "$HOME/.bashrc"; then
  echo "source $INSTALL_ROOT/Vitis/$VITIS_VER/settings64.sh 2>/dev/null || true" >> "$HOME/.bashrc"
fi

mkdir -p "$HOME/bin"
cat > "$HOME/bin/start-vivado-gui" <<SH
#!/usr/bin/env bash
set -euo pipefail
source $INSTALL_ROOT/Vitis/$VITIS_VER/settings64.sh
cd "\${1:-\$HOME}"
nohup vivado >/tmp/vivado-gui.log 2>&1 &
SH
chmod +x "$HOME/bin/start-vivado-gui"

cat > "$HOME/bin/start-vitis-gui" <<SH
#!/usr/bin/env bash
set -euo pipefail
source $INSTALL_ROOT/Vitis/$VITIS_VER/settings64.sh
WORKDIR="\${1:-\$HOME/vitis-workspace}"
mkdir -p "\$WORKDIR"
cd "\$WORKDIR"
nohup vitis -w "\$WORKDIR" >/tmp/vitis-gui.log 2>&1 &
SH
chmod +x "$HOME/bin/start-vitis-gui"

if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

cat <<MSG
Machine setup complete.

Verify services:
  systemctl status xrdp --no-pager

Then from macOS, run your fpga_devbox launcher.
MSG
