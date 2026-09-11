#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel Server ISO — containment edition
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHROOT="config/includes.chroot"
APP_DIST="$ROOT/eiciel-app-dist/EicielDashboard-linux-x64"

# ─────────────────────────────────────────────────────────────────
# EDIT THESE (or use config/config.local.env)
# ─────────────────────────────────────────────────────────────────
if [ -f "$ROOT/config/config.local.env" ]; then
  source "$ROOT/config/config.local.env"
fi
MGMT_IP="${MGMT_IP:-203.0.113.10}"
WEBHOOK_URL="${WEBHOOK_URL:-https://ntfy.sh/change-me}"
STOP_SERVICES="${STOP_SERVICES:-sshd nginx apache2 postgresql mysql mariadb redis-server docker}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-0}"
INCLUDE_DASHBOARD="${INCLUDE_DASHBOARD:-auto}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-600}"
HOSTNAME_NEW="${HOSTNAME_NEW:-eiciel-srv}"
ISO_NAME="eiciel-server"

echo "🛡️  Eiciel Server ISO builder"
echo "    MGMT_IP: $MGMT_IP"
echo "    WEBHOOK: $WEBHOOK_URL"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

# Resolve dashboard inclusion
SHIP_DASHBOARD=0
case "$INCLUDE_DASHBOARD" in
  1)    SHIP_DASHBOARD=1 ;;
  0)    SHIP_DASHBOARD=0 ;;
  auto) [ -d "$APP_DIST" ] && SHIP_DASHBOARD=1 || SHIP_DASHBOARD=0 ;;
esac
[ "$SHIP_DASHBOARD" = "1" ] && [ ! -d "$APP_DIST" ] && { echo "❌ Dashboard requested but not built. Run build-eiciel-app.sh first."; exit 1; }

# Clean
lb clean --purge >/dev/null 2>&1 || true
rm -rf config auto chroot binary cache .build local bootstrap.log chroot.log binary.log 2>/dev/null || true
mkdir -p auto config/hooks config/package-lists config/bootloaders/grub \
         config/includes.chroot/etc/eiciel config/includes.chroot/etc/audit/rules.d \
         config/includes.chroot/etc/fail2ban/jail.d config/includes.chroot/etc/systemd/system \
         config/includes.chroot/etc/ssh/sshd_config.d config/includes.chroot/etc/profile.d \
         config/includes.chroot/usr/local/sbin config/includes.chroot/root/.ssh \
         config/includes.chroot/var/lib/incidents

# auto/config
BOOTAPPEND="boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}"
[ "$ENABLE_PERSISTENCE" = "1" ] && BOOTAPPEND="$BOOTAPPEND persistence persistence-storage=filesystem"
cat > auto/config <<EOF
#!/bin/bash
set -e
lb config noauto \
    --mode debian --distribution bookworm --architectures amd64 \
    --binary-images iso-hybrid \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootappend-live "$BOOTAPPEND" \
    --linux-flavours amd64 --debian-installer false --memtest none \
    --iso-application "Eiciel Server" --iso-publisher "Eiciel" --iso-volume "EICIEL_SRV" \
    --apt-options "--yes --no-install-recommends" --apt-indices false --apt-recommends false \
    --firmware-binary false --firmware-chroot true --initramfs auto --compression xz \
    --bootloader "grub-efi grub-pc" --system live --initsystem systemd \
    --mirror-bootstrap "http://deb.debian.org/debian/" \
    --mirror-chroot "http://deb.debian.org/debian/" \
    --mirror-chroot-security "http://security.debian.org/debian-security/" \
    --mirror-binary "http://deb.debian.org/debian/" \
    --mirror-binary-security "http://security.debian.org/debian-security/"
EOF
chmod +x auto/config

# Hooks
cat > config/hooks/005-fix-sources.hook.chroot <<'EOF'
#!/bin/bash
set -e
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
cat > /etc/apt/sources.list <<'EOSRC'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOSRC
apt-get update -qq
EOF

cat > config/hooks/010-ssh.hook.chroot <<'EOF'
#!/bin/bash
set -e
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-eiciel.conf <<'EOSSH'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding yes
AllowTcpForwarding yes
MaxAuthTries 3
LoginGraceTime 20
EOSSH
systemctl enable ssh
EOF

cat > config/hooks/020-users.hook.chroot <<'EOF'
#!/bin/bash
set -e
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo admin
  passwd -l admin
fi
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 440 /etc/sudoers.d/admin
install -d -m 700 -o admin -g admin /home/admin/.ssh
EOF

# Containment config
cat > "$CHROOT/etc/eiciel/config.env" <<EOF
MGMT_IP="$MGMT_IP"
WEBHOOK_URL="$WEBHOOK_URL"
STOP_SERVICES="$STOP_SERVICES"
INCIDENT_ROOT="/var/lib/incidents"
COOLDOWN_SECONDS=$COOLDOWN_SECONDS
EOF
chmod 600 "$CHROOT/etc/eiciel/config.env"

# Containment script
cat > "$CHROOT/usr/local/sbin/eiciel-contain.sh" <<'CONTAIN_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
INCIDENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCIDENT_DIR="$INCIDENT_ROOT/$INCIDENT_ID"
mkdir -p "$INCIDENT_DIR"; chmod 700 "$INCIDENT_DIR"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$INCIDENT_DIR/containment.log" >&2; }
log "=== Incident $INCIDENT_ID starting ==="
log "Host: $(hostname)  Kernel: $(uname -r)"

# Preserve
ss -tunap > "$INCIDENT_DIR/ss.txt" 2>&1 || true
nft list ruleset > "$INCIDENT_DIR/nft-before.txt" 2>&1 || true
ip addr > "$INCIDENT_DIR/ip-addr.txt" 2>&1 || true
ps auxfww > "$INCIDENT_DIR/ps.txt" 2>&1 || true
who -a > "$INCIDENT_DIR/who.txt" 2>&1 || true
last -n 200 > "$INCIDENT_DIR/last.txt" 2>&1 || true
lsof -nP -i > "$INCIDENT_DIR/lsof-net.txt" 2>&1 || true
journalctl --since "2 hours ago" --no-pager > "$INCIDENT_DIR/journal.txt" 2>&1 || true
cp -a /var/log/audit/audit.log "$INCIDENT_DIR/" 2>/dev/null || true

# Isolate
nft delete table inet eiciel_contain 2>/dev/null || true
nft add table inet eiciel_contain
nft add chain inet eiciel_contain output '{ type filter hook output priority -10; policy drop; }'
nft add rule inet eiciel_contain output oif lo accept
nft add rule inet eiciel_contain output ct state established,related accept
nft add rule inet eiciel_contain output udp dport 53 accept
nft add rule inet eiciel_contain output tcp dport 53 accept
nft add rule inet eiciel_contain output ip daddr "$MGMT_IP" accept

# Kill sessions
while read -r user tty _; do
  [ -z "${user:-}" ] && continue; [ "$user" = "root" ] && continue; [ "$user" = "admin" ] && continue
  case "$tty" in /dev/tty*|/dev/pts/*) pkill -9 -t "${tty#/dev/}" 2>/dev/null || true ;; esac
done < <(who)

# Stop services
for svc in $STOP_SERVICES; do
  systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc" 2>/dev/null || true
done

# Notify
if [ -n "${WEBHOOK_URL:-}" ]; then
  payload=$(jq -nc --arg inc "$INCIDENT_ID" --arg host "$(hostname)" --arg time "$(date -u +%FT%TZ)" --arg dir "$INCIDENT_DIR" '{incident:$inc,host:$host,time:$time,dir:$dir}')
  curl -fsS --max-time 10 -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true
fi
logger -t eiciel "CONTAINMENT COMPLETE — $INCIDENT_ID"
CONTAIN_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-contain.sh"

# Watcher
cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
AUDIT_LOG="/var/log/audit/audit.log"; LOCK="/run/eiciel-contain.lock"; COOLDOWN="${COOLDOWN_SECONDS:-600}"
[ -f "$AUDIT_LOG" ] || exit 1
PATTERN='key="(priv_esc|priv_esc_unset|sudoers|ssh_keys|module_load|ptrace|mount)"'
tail -Fn0 "$AUDIT_LOG" 2>/dev/null | while read -r line; do
  echo "$line" | grep -qE "$PATTERN" || continue
  if [ -f "$LOCK" ] && [ $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) )) -lt "$COOLDOWN" ]; then continue; fi
  touch "$LOCK"
  logger -t eiciel "watch: high-severity event — invoking containment"
  /usr/local/sbin/eiciel-contain.sh >>/var/log/eiciel-contain.log 2>&1 || true
done
WATCH_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-watch.sh"

# Auditd rules
cat > "$CHROOT/etc/audit/rules.d/eiciel.rules" <<'AUDIT_EOF'
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -k priv_esc
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid=4294967295 -k priv_esc_unset
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /root/.ssh/ -p wa -k ssh_keys
-w /home/ -p wa -k ssh_keys
-w /etc/passwd -p wa -k accounts
-w /etc/shadow -p wa -k accounts
-a always,exit -F arch=b64 -S init_module -k module_load
-a always,exit -F arch=b64 -S finit_module -k module_load
-a always,exit -F arch=b64 -S delete_module -k module_load
-a always,exit -F arch=b64 -S ptrace -k ptrace
-a always,exit -F arch=b64 -S mount -k mount
-a always,exit -F arch=b64 -S umount2 -k mount
-e 2
AUDIT_EOF

# Fail2ban
cat > "$CHROOT/etc/fail2ban/jail.d/eiciel.local" <<'F2B_EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
action   = nftables-multiport[name=sshd, port="ssh", protocol=tcp]
F2B_EOF

# Nftables default
cat > "$CHROOT/etc/nftables.conf" <<'NFT_EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet eiciel {
    chain input { type filter hook input priority 0; policy drop; ct state established,related accept; iif lo accept; ip protocol icmp accept; ip6 nexthdr icmpv6 accept; tcp dport 22 accept; }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output { type filter hook output priority 0; policy accept; }
}
NFT_EOF

# Systemd watcher unit
cat > "$CHROOT/etc/systemd/system/eiciel-watch.service" <<'UNIT_EOF'
[Unit]
Description=Eiciel audit watcher
After=auditd.service
Requires=auditd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/eiciel-watch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Recovery runbook
cat > "$CHROOT/root/RECOVERY.md" <<'RECOVERY_EOF'
# Eiciel Server — Recovery Runbook
## 0. DO NOT power off, delete /var/lib/incidents, or "clean up".
## 1. Snapshot from hypervisor FIRST.
## 2. SSH from MGMT_IP: ssh admin@server
## 3. Copy evidence: cp -a /var/lib/incidents/ /root/incidents-preserved/
## 4. Inspect: cat /var/lib/incidents/*/containment.log
## 5. Rotate secrets: SSH keys, DB creds, app .env, cloud tokens.
## 6. Rebuild from known-good image.
## 7. Lift isolation: sudo nft delete table inet eiciel_contain
RECOVERY_EOF
chmod 644 "$CHROOT/root/RECOVERY.md"

# MOTD
cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD_EOF'
#!/bin/sh
[ -t 0 ] && cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel Server — containment stack active                ║
  ║  Config: /etc/eiciel/config.env                          ║
  ║  Evidence: /var/lib/incidents/                           ║
  ║  Recovery: /root/RECOVERY.md                             ║
  ║  Manual: sudo /usr/local/sbin/eiciel-contain.sh          ║
  ║  Lift: sudo nft delete table inet eiciel_contain         ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
MOTD_EOF
chmod 755 "$CHROOT/etc/profile.d/eiciel-motd.sh"

# Authorized key
if [ -n "$SSH_AUTHORIZED_KEY" ]; then
  echo "$SSH_AUTHORIZED_KEY" > "$CHROOT/root/.ssh/authorized_keys"
  chmod 600 "$CHROOT/root/.ssh/authorized_keys"
  cat > config/hooks/025-authorized-keys.hook.chroot <<'EOF'
#!/bin/bash
set -e
[ -f /root/.ssh/authorized_keys ] && {
  install -d -m 700 -o admin -g admin /home/admin/.ssh
  cp /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
  chown admin:admin /home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
}
EOF
  chmod +x config/hooks/025-authorized-keys.hook.chroot
fi

# Dashboard ship
if [ "$SHIP_DASHBOARD" = "1" ]; then
  install -d -m 755 "$CHROOT/opt/eiciel-dashboard"
  cp -a "$APP_DIST/." "$CHROOT/opt/eiciel-dashboard/"
  chmod -R 755 "$CHROOT/opt/eiciel-dashboard"
  cat > config/hooks/035-dashboard.hook.chroot <<'EOF'
#!/bin/bash
set -e
cat > /usr/local/bin/eiciel-dashboard <<'LAUNCH'
#!/bin/bash
exec /opt/eiciel-dashboard/EicielDashboard --no-sandbox --disable-gpu-sandbox "$@"
LAUNCH
chmod 755 /usr/local/bin/eiciel-dashboard
cat > /etc/sudoers.d/eiciel-dashboard <<'SUDO'
admin ALL=(root) NOPASSWD: /usr/local/sbin/eiciel-contain.sh
admin ALL=(root) NOPASSWD: /usr/sbin/nft delete table inet eiciel_contain
admin ALL=(root) NOPASSWD: /bin/systemctl is-active *
admin ALL=(root) NOPASSWD: /usr/bin/journalctl -u eiciel-watch *
admin ALL=(root) NOPASSWD: /usr/sbin/ausearch *
admin ALL=(root) NOPASSWD: /bin/ls /var/lib/incidents
admin ALL=(root) NOPASSWD: /bin/cat /var/lib/incidents/*
SUDO
chmod 440 /etc/sudoers.d/eiciel-dashboard
EOF
  chmod +x config/hooks/035-dashboard.hook.chroot
fi

# Enable services hook
cat > config/hooks/030-enable-services.hook.chroot <<'EOF'
#!/bin/bash
set -e
systemctl enable auditd; augenrules --load 2>/dev/null || true
systemctl enable fail2ban nftables ssh eiciel-watch systemd-journald
install -d -m 2755 /var/log/journal
EOF
chmod +x config/hooks/030-enable-services.hook.chroot

# Verify hook
cat > config/hooks/040-verify.hook.chroot <<'EOF'
#!/bin/bash
set -e
fail=0
for f in /usr/local/sbin/eiciel-contain.sh /usr/local/sbin/eiciel-watch.sh /etc/eiciel/config.env /etc/audit/rules.d/eiciel.rules /etc/fail2ban/jail.d/eiciel.local /etc/nftables.conf /etc/systemd/system/eiciel-watch.service /root/RECOVERY.md /etc/profile.d/eiciel-motd.sh; do
  [ -e "$f" ] || { echo "❌ missing: $f"; fail=1; }
done
[ -x /usr/local/sbin/eiciel-contain.sh ] || fail=1
[ -x /usr/local/sbin/eiciel-watch.sh ] || fail=1
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || fail=1
[ "$fail" -eq 0 ] || exit 1
echo "✅ All checks passed."
EOF
chmod +x config/hooks/040-verify.hook.chroot

# Cleanup hook
cat > config/hooks/060-cleanup.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get autoremove -y || true; apt-get clean || true
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
chmod 644 /root/RECOVERY.md; chmod 755 /usr/local/sbin/eiciel-contain.sh /usr/local/sbin/eiciel-watch.sh; chmod 600 /etc/eiciel/config.env
EOF
chmod +x config/hooks/060-cleanup.hook.chroot

# Package list
cat > config/package-lists/eiciel.list.chroot <<'EOF'
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
openssh-server
nano
vim-tiny
htop
psmisc
lsof
strace
auditd
audispd-plugins
fail2ban
nftables
acl
attr
rsyslog
restic
curl
wget
jq
unzip
p7zip-full
rsync
firmware-linux-free
firmware-linux-nonfree
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-brcm80211
network-manager
rfkill
wireless-tools
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
EOF

# Static files
echo "$HOSTNAME_NEW" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_NEW
::1         localhost ip6-localhost ip6-loopback
EOF
cat > "$CHROOT/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Eiciel Server"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
GRUB_CMDLINE_LINUX=""
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF

# GRUB menu
cat > config/bootloaders/grub/config.cfg <<'EOF'
set timeout=3
set default=0
set gfxmode=auto
set gfxpayload=keep
insmod all_video
terminal_output console

menuentry "Eiciel Server" {
    linux  /live/vmlinuz boot=live components quiet loglevel=3 username=admin hostname=eiciel-srv
    initrd /live/initrd.img
}
menuentry "Eiciel Server (verbose)" {
    linux  /live/vmlinuz boot=live components username=admin hostname=eiciel-srv
    initrd /live/initrd.img
}
menuentry "Eiciel Server (recovery shell)" {
    linux  /live/vmlinuz boot=live components single username=admin hostname=eiciel-srv
    initrd /live/initrd.img
}
EOF

# Build
echo "📦 Configuring live-build…"
./auto/config
echo "📦 Running debootstrap…"
lb bootstrap 2>&1 | tee bootstrap.log
[ -x "chroot/bin/sh" ] || { echo "❌ Bootstrap failed."; tail -40 bootstrap.log; exit 1; }
echo "📦 Running chroot stage…"
lb chroot 2>&1 | tee chroot.log
echo "📦 Running binary stage…"
lb binary 2>&1 | tee binary.log

# Report
ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
[ -n "$ISO" ] || { echo "❌ No ISO produced."; exit 1; }
[ "$ISO" != "${ISO_NAME}.iso" ] && mv "$ISO" "${ISO_NAME}.iso" && ISO="${ISO_NAME}.iso"
echo "✅ Done! $ROOT/$ISO ($(du -h "$ISO" | cut -f1))"
