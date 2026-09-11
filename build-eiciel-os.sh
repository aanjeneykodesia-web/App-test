#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel OS – Standalone ISO builder (single-file)
#
#  Usage:
#    1. Put this script in a folder that ALSO contains "eiciel-electron/"
#       (your existing Electron project).
#    2. Run:   chmod +x build-eiciel-os.sh && sudo ./build-eiciel-os.sh
#
#  Requires (Debian/Ubuntu host):
#    sudo apt install live-build debootstrap xorriso squashfs-tools \
#                     mtools dosfstools grub-efi-amd64-bin grub-pc-bin \
#                     nodejs npm
#
#  Output:  ./eiciel-os.iso   (~700 MB, bootable USB / VM)
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ISO_NAME="eiciel-os"
APP_SRC="eiciel-electron"
CHROOT_APP="config/includes.chroot/opt/eiciel"

echo "🛡️  Eiciel OS – standalone ISO build"
echo "    root: $ROOT"
echo ""

# ─────────────────────────────────────────────────────────────
# 0. Sanity checks
# ─────────────────────────────────────────────────────────────
if [ ! -d "$APP_SRC" ]; then
  echo "❌ Missing '$APP_SRC/'. Put your Electron project next to this script."
  exit 1
fi

for cmd in lb debootstrap xorriso mksquashfs node npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Missing tool: $cmd"
    echo "   Install with:  sudo apt install live-build debootstrap xorriso squashfs-tools mtools dosfstools grub-efi-amd64-bin grub-pc-bin nodejs npm"
    exit 1
  fi
done

mkdir -p config/includes.chroot/etc/systemd/system
mkdir -p config/includes.chroot/etc/X11/xorg.conf.d
mkdir -p config/includes.chroot/etc/default
mkdir -p config/includes.chroot/opt/eiciel
mkdir -p config/includes.binary/boot/grub
mkdir -p config/hooks
mkdir -p config/package-lists
mkdir -p config/bootloaders/grub
mkdir -p auto

# ─────────────────────────────────────────────────────────────
# 1. Build the Electron app for Linux x64
# ─────────────────────────────────────────────────────────────
echo "📦 [1/6] Building Electron app (linux-x64)…"
(
  cd "$APP_SRC"
  npm install --no-audit --no-fund --loglevel=error
  if [ ! -d "dist/EicielOS-linux-x64" ]; then
    npx electron-packager . EicielOS \
      --platform=linux --arch=x64 \
      --out=./dist --overwrite --no-prune
  fi
)

echo "📦 [2/6] Staging app into chroot…"
rm -rf "$CHROOT_APP"
mkdir -p "$CHROOT_APP"
cp -a "$APP_SRC/dist/EicielOS-linux-x64/." "$CHROOT_APP/"
chmod -R 755 "$CHROOT_APP"

# ─────────────────────────────────────────────────────────────
# 2. auto/config
# ─────────────────────────────────────────────────────────────
cat > auto/config << 'EOF'
#!/bin/bash
set -e
lb config noauto \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "boot=live components quiet splash loglevel=0 username=eiciel hostname=eiciel" \
    --linux-flavours amd64 \
    --debian-installer false \
    --memtest none \
    --iso-application "Eiciel OS" \
    --iso-publisher "Eiciel" \
    --iso-volume "EICIEL_OS" \
    --apt-options "--yes --no-install-recommends" \
    --apt-indices false \
    --apt-recommends false \
    --firmware-binary false \
    --firmware-chroot false \
    --initramfs compact \
    --compression xz \
    --bootloader grub-efi \
    --system live \
    --initsystem systemd \
    --updates false \
    --security false \
    --backports false \
    --mirror-bootstrap "http://deb.debian.org/debian/" \
    --mirror-chroot "http://deb.debian.org/debian/" \
    --mirror-chroot-security "http://deb.debian.org/debian-security/" \
    --mirror-binary "http://deb.debian.org/debian/" \
    --mirror-binary-security "http://deb.debian.org/debian-security/"
EOF
chmod +x auto/config

# ─────────────────────────────────────────────────────────────
# 3. Package list
# ─────────────────────────────────────────────────────────────
cat > config/package-lists/eiciel.list.chroot << 'EOF'
linux-image-amd64
live-boot
live-config
systemd
systemd-sysv
sudo
locales
console-setup
kbd
hostname
ca-certificates
xserver-xorg
xserver-xorg-core
xserver-xorg-input-all
xserver-xorg-video-all
xinit
x11-xserver-utils
openbox
unclutter
pulseaudio
alsa-utils
network-manager
rfkill
wireless-tools
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-brcm80211
firmware-misc-nonfree
bluez
bluez-tools
usbutils
pciutils
nodejs
npm
libnss3
libatk1.0-0
libatk-bridge2.0-0
libcups2
libdrm2
libxkbcommon0
libxcomposite1
libxdamage1
libxfixes3
libxrandr2
libgbm1
libpango-1.0-0
libcairo2
libasound2
libatspi2.0-0
libgtk-3-0
fonts-liberation
fonts-dejavu
nftables
curl
wget
unzip
p7zip-full
nano
htop
EOF

# ─────────────────────────────────────────────────────────────
# 4. Hooks
# ─────────────────────────────────────────────────────────────
cat > config/hooks/010-nodejs.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[010] Installing Node.js 20…"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
EOF

cat > config/hooks/020-user.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[020] Creating eiciel user…"
if ! id -u eiciel >/dev/null 2>&1; then
  useradd -m -s /bin/bash eiciel
  echo "eiciel:eiciel" | chpasswd
  usermod -aG sudo,audio,video,netdev,bluetooth,cdrom eiciel
  echo "eiciel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/eiciel
  chmod 440 /etc/sudoers.d/eiciel
fi
chown -R eiciel:eiciel /opt/eiciel
chmod -R 755 /opt/eiciel
EOF

cat > config/hooks/030-shell.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[030] Installing Eiciel shell service…"

cat > /etc/systemd/system/eiciel-shell.service << 'EOSVC'
[Unit]
Description=Eiciel OS Shell
After=systemd-user-sessions.service network.target NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
User=eiciel
Environment=DISPLAY=:0
Environment=HOME=/home/eiciel
Environment=EICIEL_TEST_MODE=0
WorkingDirectory=/opt/eiciel
ExecStart=/usr/bin/startx /opt/eiciel/EicielOS --no-sandbox --disable-gpu-sandbox --kiosk
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOSVC

systemctl enable eiciel-shell.service

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOAL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin eiciel --noclear %I $TERM
EOAL

cat > /home/eiciel/.bash_profile << 'EOBP'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx /opt/eiciel/EicielOS --no-sandbox --disable-gpu-sandbox --kiosk
fi
EOBP
chown eiciel:eiciel /home/eiciel/.bash_profile

mkdir -p /home/eiciel/.config/openbox
cat > /home/eiciel/.config/openbox/rc.xml << 'EOOB'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>yes</maximized>
      <position force="yes"><x>0</x><y>0</y></position>
    </application>
  </applications>
  <keyboard></keyboard>
</openbox_config>
EOOB
chown -R eiciel:eiciel /home/eiciel/.config
EOF

cat > config/hooks/040-firewall.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[040] Firewall…"
cat > /etc/nftables.conf << 'EONFT'
#!/usr/sbin/nft -f
flush ruleset
table inet eiciel {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EONFT
systemctl enable nftables
EOF

cat > config/hooks/050-hardening.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[050] Hardening…"
systemctl mask ctrl-alt-del.target || true

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-kiosk.conf << 'EOX'
Section "ServerFlags"
    Option "DontVTSwitch" "True"
    Option "DontZap"      "True"
    Option "DontZoom"     "True"
EndSection
EOX

cat > /etc/X11/xorg.conf.d/98-no-blank.conf << 'EOB'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOB

grep -q '^NAutoVTs=' /etc/systemd/logind.conf || echo "NAutoVTs=1" >> /etc/systemd/logind.conf
grep -q '^ReserveVT=' /etc/systemd/logind.conf || echo "ReserveVT=1" >> /etc/systemd/logind.conf
EOF

cat > config/hooks/060-cleanup.hook.chroot << 'EOF'
#!/bin/bash
set -e
echo "[060] Cleanup…"
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
EOF

chmod +x config/hooks/*.hook.chroot

# ─────────────────────────────────────────────────────────────
# 5. Static chroot files
# ─────────────────────────────────────────────────────────────
echo "eiciel" > config/includes.chroot/etc/hostname

cat > config/includes.chroot/etc/default/grub << 'EOF'
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Eiciel OS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0"
GRUB_CMDLINE_LINUX=""
GRUB_GFXMODE=1920x1080
GRUB_GFXPAYLOAD_LINUX=keep
EOF

cat > config/includes.chroot/etc/X11/xorg.conf.d/99-kiosk.conf << 'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "True"
    Option "DontZap"      "True"
    Option "DontZoom"     "True"
EndSection
EOF

cat > config/includes.chroot/etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet eiciel {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

# ─────────────────────────────────────────────────────────────
# 6. GRUB bootloader
# ─────────────────────────────────────────────────────────────
cat > config/bootloaders/grub/config.cfg << 'EOF'
set timeout=3
set default=0

set gfxmode=1920x1080
set gfxpayload=keep
insmod gfxterm
insmod png
terminal_output gfxterm

menuentry "Eiciel OS" {
    linux  /live/vmlinuz boot=live components quiet splash loglevel=0 username=eiciel hostname=eiciel
    initrd /live/initrd.img
}

menuentry "Eiciel OS (safe mode)" {
    linux  /live/vmlinuz boot=live components username=eiciel nomodeset
    initrd /live/initrd.img
}

menuentry "Eiciel OS (recovery shell)" {
    linux  /live/vmlinuz boot=live components username=eiciel single
    initrd /live/initrd.img
}
EOF

# ─────────────────────────────────────────────────────────────
# 7. Build the ISO
# ─────────────────────────────────────────────────────────────
echo "📦 [3/6] Configuring live-build…"
lb clean --purge >/dev/null 2>&1 || true
./auto/config

echo "📦 [4/6] Running live-build (15–25 min)…"
lb build 2>&1 | tee build.log

# ─────────────────────────────────────────────────────────────
# 8. Report
# ─────────────────────────────────────────────────────────────
ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
if [ -z "$ISO" ]; then
  echo "❌ No ISO produced. Check build.log."
  exit 1
fi

# Rename to a friendly name
if [ "$ISO" != "${ISO_NAME}.iso" ]; then
  mv "$ISO" "${ISO_NAME}.iso"
  ISO="${ISO_NAME}.iso"
fi

SIZE=$(du -h "$ISO" | cut -f1)
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅  Done!  $ROOT/$ISO   ($SIZE)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Flash to USB:"
echo "    sudo dd if=$ISO of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
echo "Test in QEMU:"
echo "    qemu-system-x86_64 -m 4096 -cdrom $ISO -boot d"
echo ""
echo "Boot behaviour:"
echo "    GRUB menu  →  live kernel  →  auto-login eiciel"
echo "    →  X + Openbox (kiosk)  →  /opt/eiciel/EicielOS"
echo ""
