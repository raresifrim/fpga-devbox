#!/usr/bin/env bash
set -euo pipefail

INSTALLER_PATH="${1:-}"
VITIS_VER="${VITIS_VER:-2025.2}"
VITIS_EDITION="${VITIS_EDITION:-Vitis Unified Software Platform}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
INSTALL_CONFIG="${INSTALL_CONFIG:-}"

prepare_install_config() {
  local src="$1"
  local dst="$2"
  local install_root="$3"

  if grep -E '^Modules=.*,' "$src" >/dev/null 2>&1; then
    cp "$src" "$dst"
  else
    local -a header=()
    local -a modules=()
    local -a footer=()
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
        *:0|*:1)
          modules+=("$line")
          ;;
        *)
          [[ "$line" =~ ^#### ]] && header+=("$line")
          ;;
      esac
    done < "$src"

    if ((${#modules[@]} == 0)); then
      echo "Install config has no module entries: $src" >&2
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
      printf 'Modules='
      local i
      for i in "${!modules[@]}"; do
        ((i)) && printf ','
        printf '%s' "${modules[$i]}"
      done
      printf '\n'
      for line in "${footer[@]}"; do
        echo "$line"
      done
    } > "$dst"
  fi

  if ! grep -q '^Destination=' "$dst"; then
    echo "Destination=$install_root" >> "$dst"
  fi
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
  verilator iverilog

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

echo "Running batch install with $SETUP_BIN"
if [[ -n "$INSTALL_CONFIG" ]]; then
  [[ -f "$INSTALL_CONFIG" ]] || { echo "Install config not found: $INSTALL_CONFIG" >&2; exit 1; }
  COMPILED_INSTALL_CONFIG="$HOME/.xilinx-install-config.compiled.txt"
  prepare_install_config "$INSTALL_CONFIG" "$COMPILED_INSTALL_CONFIG" "$INSTALL_ROOT"
  echo "Using install config: $INSTALL_CONFIG (compiled to $COMPILED_INSTALL_CONFIG)"
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
