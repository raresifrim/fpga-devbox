#!/usr/bin/env bash
set -euo pipefail

INSTALLER_PATH="${1:-}"
VITIS_VER="${VITIS_VER:-2025.2}"
INSTALL_ROOT="${INSTALL_ROOT:-/tools/Xilinx}"
INSTALL_CONFIG_PATH="$HOME/install_config.txt"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") /path/in/linux/to/Xilinx_Unified_2025.2_*.bin|*.tar.gz

Environment overrides:
  VITIS_VER=2025.2
  INSTALL_ROOT=/tools/Xilinx
USAGE
}

[[ -n "$INSTALLER_PATH" ]] || { usage; exit 1; }
[[ -e "$INSTALLER_PATH" ]] || { echo "Installer not found in machine: $INSTALLER_PATH" >&2; exit 1; }

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
  xfce4 xfce4-goodies xrdp xorgxrdp dbus-x11 x11-xserver-utils \
  build-essential git wget curl unzip file p7zip-full \
  libglib2.0-0 libsm6 libxi6 libxrender1 libxrandr2 \
  libfreetype6 libfontconfig1 libxext6 libxtst6 libx11-6 \
  libgtk2.0-0 libxcb1 libxcb-util1 \
  libtinfo5 libncurses5 python3 python3-pip locales lsb-release usbutils \
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
sudo systemctl enable --now xrdp
sudo systemctl restart xrdp

sudo mkdir -p "$INSTALL_ROOT"
sudo chown -R "$USER":"$USER" "$INSTALL_ROOT"

cat > "$INSTALL_CONFIG_PATH" <<CFG
Edition=Vitis Unified Software Platform
Product=Vitis
Destination=$INSTALL_ROOT
Modules=Zynq-7000:1,Zynq UltraScale+ MPSoC:1,Kintex UltraScale+:1,Artix UltraScale+:1,Kintex-7:1,Artix-7:1,Spartan-7:1,Virtex UltraScale+:0,Versal AI Core Series:0,DocNav:0,Vitis Model Composer:0,Install Devices for Kria SOMs and Starter Kits:0,Vitis IP Cache (Enable faster on-boarding for new users):0,Engineering Sample Devices for Custom Platforms:0
InstallOptions=Acquire or Manage a License Key:0,Enable WebTalk for SDK to send usage statistics to Xilinx:0
Perform System Checks:1
Install Cable Drivers:1
CreateProgramGroupShortcuts=0
CreateShortcutsForAllUsers=0
CreateDesktopShortcuts=0
CreateFileAssociation=0
EnableDiskUsageOptimization=1
CFG

WORKDIR="$HOME/xilinx-installer"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

case "$INSTALLER_PATH" in
  *.tar.gz)
    tar -xzf "$INSTALLER_PATH" -C "$WORKDIR"
    INSTALL_DIR="$(find "$WORKDIR" -maxdepth 1 -type d -name 'Xilinx_Unified_*' | head -n1)"
    ;;
  *.bin)
    cp "$INSTALLER_PATH" "$WORKDIR/installer.bin"
    chmod +x "$WORKDIR/installer.bin"
    INSTALL_DIR="$WORKDIR"
    ;;
  *)
    echo "Unsupported installer format: $INSTALLER_PATH" >&2
    exit 1
    ;;
esac

if [[ -x "$INSTALL_DIR/xsetup" ]]; then
  SETUP_BIN="$INSTALL_DIR/xsetup"
elif [[ -x "$WORKDIR/installer.bin" ]]; then
  SETUP_BIN="$WORKDIR/installer.bin"
else
  echo "Could not locate xsetup/installer executable" >&2
  exit 1
fi

"$SETUP_BIN" --agree XilinxEULA,3rdPartyEULA --batch Install --config "$INSTALL_CONFIG_PATH"

if ! grep -q "/tools/Xilinx/Vitis/$VITIS_VER/settings64.sh" "$HOME/.bashrc"; then
  echo "source /tools/Xilinx/Vitis/$VITIS_VER/settings64.sh 2>/dev/null || true" >> "$HOME/.bashrc"
fi

mkdir -p "$HOME/bin"
cat > "$HOME/bin/start-vivado-gui" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /tools/Xilinx/Vitis/2025.2/settings64.sh
cd "${1:-$HOME}"
nohup vivado >/tmp/vivado-gui.log 2>&1 &
SH
chmod +x "$HOME/bin/start-vivado-gui"

cat > "$HOME/bin/start-vitis-gui" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /tools/Xilinx/Vitis/2025.2/settings64.sh
WORKDIR="${1:-$HOME/vitis-workspace}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
nohup vitis -w "$WORKDIR" >/tmp/vitis-gui.log 2>&1 &
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
