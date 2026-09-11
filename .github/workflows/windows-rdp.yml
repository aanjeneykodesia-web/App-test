#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel Server ISO — containment edition
#  Debian 12 (bookworm) live ISO shipping:
#    - auditd high-severity rules
#    - fail2ban on SSH
#    - nftables default-deny inbound + containment table
#    - containment script (preserve → contain → notify; never destroy)
#    - systemd watcher that fires containment on auditd events
#    - restic for optional off-host evidence push
#    - openssh-server for remote admin
#    - recovery runbook at /root/RECOVERY.md
#
#  Build host: Debian 12 (use container: debian:bookworm in CI)
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
  # shellcheck disable=SC1091
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

echo "═══════════════════════════════════════════════════════════════"
echo "  Eiciel Server ISO builder"
echo "  MGMT_IP       = $MGMT_IP"
echo "  WEBHOOK_URL   = $WEBHOOK_URL"
echo "  STOP_SERVICES = $STOP_SERVICES"
echo "  SSH_KEY       = ${SSH_AUTHORIZED_KEY:0:40}${SSH_AUTHORIZED_KEY:+...}"
echo "  PERSISTENCE   = $ENABLE_PERSISTENCE"
echo "  DASHBOARD     = $INCLUDE_DASHBOARD"
echo "═══════════════════════════════════════════════════════════════"

[[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }

# ─────────────────────────────────────────────────────────────────
# 0. Sanity
# ─────────────────────────────────────────────────────────────────
for cmd in lb debootstrap xorriso mksquashfs; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "❌ Missing tool: $cmd"
    echo "   apt-get install live-build debootstrap xorriso squashfs-tools mtools dosfstools grub-efi-amd64-bin grub-pc-bin"
    exit 1
  }
done

# Resolve dashboard inclusion
SHIP_DASHBOARD=0
case "$INCLUDE_DASHBOARD" in
  1)    SHIP_DASHBOARD=1 ;;
  0)    SHIP_DASHBOARD=0 ;;
  auto) [ -d "$APP_DIST" ] && SHIP_DASHBOARD=1 || SHIP_DASHBOARD=0 ;;
  *)    echo "❌ INCLUDE_DASHBOARD must be auto|0|1"; exit 1 ;;
esac
if [ "$SHIP_DASHBOARD" = "1" ] && [ ! -d "$APP_DIST" ]; then
  echo "❌ Dashboard requested but $APP_DIST missing."
  echo "   Run ./scripts/build-eiciel-app.sh first, or set INCLUDE_DASHBOARD=0."
  exit 1
fi
echo "   → dashboard will ${SHIP_DASHBOARD:+NOT }be shipped"
[ "$SHIP_DASHBOARD" = "1" ] && echo "     (source: $APP_DIST)"

# ─────────────────────────────────────────────────────────────────
# 1. Clean
# ─────────────────────────────────────────────────────────────────
echo "📦 Cleaning old build state…"
lb clean --purge >/dev/null 2>&1 || true
rm -rf config auto chroot binary cache .build local \
       bootstrap.log chroot.log binary.log 2>/dev/null || true

mkdir -p auto \
         config/hooks \
         config/package-lists \
         config/bootloaders/grub \
         config/includes.chroot/etc/eiciel \
         config/includes.chroot/etc/audit/rules.d \
         config/includes.chroot/etc/fail2ban/jail.d \
         config/includes.chroot/etc/systemd/system \
         config/includes.chroot/etc/ssh/sshd_config.d \
         config/includes.chroot/etc/profile.d \
         config/includes.chroot/etc/default \
         config/includes.chroot/usr/local/sbin \
         config/includes.chroot/root/.ssh \
         config/includes.chroot/var/lib/incidents

# ─────────────────────────────────────────────────────────────────
# 2. auto/config
# ─────────────────────────────────────────────────────────────────
BOOTAPPEND="boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}"
[ "$ENABLE_PERSISTENCE" = "1" ] && \
  BOOTAPPEND="$BOOTAPPEND persistence persistence-storage=filesystem"

cat > auto/config <<EOF
#!/bin/bash
set -e
lb config noauto \\
    --mode debian \\
    --distribution bookworm \\
    --architectures amd64 \\
    --binary-images iso-hybrid \\
    --archive-areas "main contrib non-free non-free-firmware" \\
    --bootappend-live "$BOOTAPPEND" \\
    --linux-flavours amd64 \\
    --debian-installer none \\
    --memtest none \\
    --iso-application "Eiciel Server" \\
    --iso-publisher "Eiciel" \\
    --iso-volume "EICIEL_SRV" \\
    --apt-options "--yes --no-install-recommends" \\
    --apt-indices false \\
    --apt-recommends false \\
    --firmware-binary false \\
    --firmware-chroot true \\
    --initramfs live-boot \\
    --compression xz \\
    --bootloader "grub-efi grub-pc" \\
    --system live \\
    --initsystem systemd \\
    --mirror-bootstrap "http://deb.debian.org/debian/" \\
    --mirror-chroot "http://deb.debian.org/debian/" \\
    --mirror-chroot-security "http://security.debian.org/debian-security/" \\
    --mirror-binary "http://deb.debian.org/debian/" \\
    --mirror-binary-security "http://security.debian.org/debian-security/"
EOF
chmod +x auto/config

# ─────────────────────────────────────────────────────────────────
# 3. Hook 005 — apt sources
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/005-fix-sources.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[005] Fixing apt sources…"
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
cat > /etc/apt/sources.list <<'EOSRC'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOSRC
apt-get update -qq
EOF

# ─────────────────────────────────────────────────────────────────
# 4. Hook 010 — sshd
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/010-ssh.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[010] Hardening sshd…"
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
ClientAliveInterval 300
ClientAliveCountMax 2
EOSSH
systemctl enable ssh
EOF

# ─────────────────────────────────────────────────────────────────
# 5. Hook 020 — admin user
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/020-users.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[020] Creating admin user…"
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo admin
  passwd -l admin
fi
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 440 /etc/sudoers.d/admin
install -d -m 700 -o admin -g admin /home/admin/.ssh
EOF

# ─────────────────────────────────────────────────────────────────
# 6. Containment stack — static files
# ─────────────────────────────────────────────────────────────────
cat > "$CHROOT/etc/eiciel/config.env" <<EOF
# Eiciel containment config — chmod 600
MGMT_IP="$MGMT_IP"
WEBHOOK_URL="$WEBHOOK_URL"
STOP_SERVICES="$STOP_SERVICES"
INCIDENT_ROOT="/var/lib/incidents"
COOLDOWN_SECONDS=$COOLDOWN_SECONDS
# RESTIC_REPO="s3:https://s3.amazonaws.com/your-bucket/incidents"
# RESTIC_PASSWORD_FILE="/etc/eiciel/restic.pass"
EOF
chmod 600 "$CHROOT/etc/eiciel/config.env"

# ─── Containment script ───
cat > "$CHROOT/usr/local/sbin/eiciel-contain.sh" <<'CONTAIN_EOF'
#!/bin/bash
# Breach containment — preserve, contain, notify. Never destroy.
set -euo pipefail
source /etc/eiciel/config.env

INCIDENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCIDENT_DIR="$INCIDENT_ROOT/$INCIDENT_ID"
mkdir -p "$INCIDENT_DIR"
chmod 700 "$INCIDENT_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$INCIDENT_DIR/containment.log" >&2; }

log "=== Incident $INCIDENT_ID starting ==="
log "Host: $(hostname)  Kernel: $(uname -r)  Uptime: $(uptime -p 2>/dev/null || uptime)"

# ── 1. PRESERVE EVIDENCE ────────────────────────────────────────
log "Preserving evidence to $INCIDENT_DIR ..."

ss -tunap                > "$INCIDENT_DIR/ss.txt"              2>&1 || true
nft list ruleset         > "$INCIDENT_DIR/nft-before.txt"      2>&1 || true
iptables-save            > "$INCIDENT_DIR/iptables-before.txt" 2>&1 || true
ip addr                  > "$INCIDENT_DIR/ip-addr.txt"         2>&1 || true
ip route                 > "$INCIDENT_DIR/ip-route.txt"        2>&1 || true
ip neigh                 > "$INCIDENT_DIR/arp.txt"             2>&1 || true
ps auxfww                > "$INCIDENT_DIR/ps.txt"              2>&1 || true
pstree -ap               > "$INCIDENT_DIR/pstree.txt"          2>&1 || true
who -a                   > "$INCIDENT_DIR/who.txt"             2>&1 || true
w                        > "$INCIDENT_DIR/w.txt"               2>&1 || true
last -n 200              > "$INCIDENT_DIR/last.txt"            2>&1 || true
lastb -n 200             > "$INCIDENT_DIR/lastb.txt"           2>&1 || true
lsof -nP -i              > "$INCIDENT_DIR/lsof-net.txt"        2>&1 || true
lsmod                    > "$INCIDENT_DIR/lsmod.txt"           2>&1 || true
mount                    > "$INCIDENT_DIR/mount.txt"           2>&1 || true
df -h                    > "$INCIDENT_DIR/df.txt"              2>&1 || true
env | sort               > "$INCIDENT_DIR/env.txt"             2>&1 || true

for f in /var/log/auth.log /var/log/syslog /var/log/secure \
         /var/log/messages /var/log/kern.log \
         /var/log/nginx/access.log /var/log/nginx/error.log \
         /var/log/apache2/access.log /var/log/apache2/error.log; do
  [ -f "$f" ] && cp -a "$f" "$INCIDENT_DIR/" 2>/dev/null || true
done
journalctl --since "2 hours ago" --no-pager > "$INCIDENT_DIR/journal.txt" 2>&1 || true
cp -a /var/log/audit/audit.log "$INCIDENT_DIR/" 2>/dev/null || true

stat /etc/passwd /etc/shadow /etc/sudoers /etc/ssh/sshd_config \
     /root/.ssh/authorized_keys 2>/dev/null \
  > "$INCIDENT_DIR/keyfiles-stat.txt" || true

{
  echo "# pid exe_path sha256"
  for pid in /proc/[0-9]*; do
    p="${pid#/proc/}"
    exe="$(readlink -f "$pid/exe" 2>/dev/null || true)"
    [ -n "$exe" ] && [ -f "$exe" ] || continue
    sum="$(sha256sum "$exe" 2>/dev/null | awk '{print $1}')"
    echo "$p $exe $sum"
  done
} > "$INCIDENT_DIR/proc-exe-hashes.txt" 2>/dev/null || true

log "Evidence preserved."

# ── 2. ISOLATE NETWORK ─────────────────────────────────────────
log "Isolating network (outbound drop; MGMT_IP=$MGMT_IP allowed)…"

nft delete table inet eiciel_contain 2>/dev/null || true
nft add table inet eiciel_contain
nft add chain inet eiciel_contain output '{ type filter hook output priority -10; policy drop; }'
nft add rule inet eiciel_contain output oif lo accept
nft add rule inet eiciel_contain output ct state established,related accept
nft add rule inet eiciel_contain output udp dport 53 accept
nft add rule inet eiciel_contain output tcp dport 53 accept
nft add rule inet eiciel_contain output ip daddr "$MGMT_IP" accept

log "Outbound locked."

# ── 3. KILL ATTACKER SESSIONS ──────────────────────────────────
log "Terminating non-admin TTY sessions…"
while read -r user tty _; do
  [ -z "${user:-}" ] && continue
  [ "$user" = "root" ] && continue
  [ "$user" = "admin" ] && continue
  case "$tty" in
    /dev/tty*|/dev/pts/*) ;;
    *) continue ;;
  esac
  log "  killing user=$user tty=$tty"
  pkill -9 -t "${tty#/dev/}" 2>/dev/null || true
done < <(who)

# ── 4. STOP EXPOSED SERVICES ───────────────────────────────────
for svc in $STOP_SERVICES; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "Stopping $svc (graceful)"
    systemctl stop "$svc" 2>/dev/null || true
  fi
done

# ── 5. PUSH OFF-HOST (optional) ────────────────────────────────
if [ -n "${RESTIC_REPO:-}" ] && [ -f "${RESTIC_PASSWORD_FILE:-/dev/null}" ]; then
  log "Pushing incident to $RESTIC_REPO ..."
  restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
      backup "$INCIDENT_DIR" >/dev/null 2>&1 \
    && log "restic backup ok" || log "restic backup FAILED"
fi

# ── 6. NOTIFY ──────────────────────────────────────────────────
log "Sending notification…"
if [ -n "${WEBHOOK_URL:-}" ]; then
  payload=$(jq -nc \
    --arg inc "$INCIDENT_ID" \
    --arg host "$(hostname)" \
    --arg time "$(date -u +%FT%TZ)" \
    --arg dir "$INCIDENT_DIR" \
    --arg svc "$STOP_SERVICES" \
    '{incident:$inc,host:$host,time:$time,dir:$dir,services_stopped:$svc}')
  curl -fsS --max-time 10 -X POST "$WEBHOOK_URL" \
    -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 \
    && log "webhook ok" || log "webhook FAILED"
fi

logger -t eiciel "CONTAINMENT COMPLETE — incident $INCIDENT_ID — evidence in $INCIDENT_DIR"
log "=== Containment complete ==="
echo "$INCIDENT_DIR"
CONTAIN_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-contain.sh"

# ─── Watcher ───
cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

AUDIT_LOG="/var/log/audit/audit.log"
LOCK="/run/eiciel-contain.lock"
COOLDOWN="${COOLDOWN_SECONDS:-600}"

[ -f "$AUDIT_LOG" ] || { logger -t eiciel "watch: $AUDIT_LOG missing"; exit 1; }

PATTERN='key="(priv_esc|priv_esc_unset|sudoers|ssh_keys|module_load|ptrace|mount)"'

logger -t eiciel "watch: starting, tailing $AUDIT_LOG"
tail -Fn0 "$AUDIT_LOG" 2>/dev/null | while read -r line; do
  echo "$line" | grep -qE "$PATTERN" || continue
  if [ -f "$LOCK" ]; then
    last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ $(( now - last )) -lt "$COOLDOWN" ]; then continue; fi
  fi
  touch "$LOCK"
  logger -t eiciel "watch: high-severity audit event — invoking containment"
  /usr/local/sbin/eiciel-contain.sh >>/var/log/eiciel-contain.log 2>&1 || \
    logger -t eiciel "watch: containment FAILED"
done
WATCH_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-watch.sh"

# ─── auditd rules ───
cat > "$CHROOT/etc/audit/rules.d/eiciel.rules" <<'AUDIT_EOF'
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -k priv_esc
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid=4294967295 -k priv_esc_unset

-w /etc/sudoers          -p wa -k sudoers
-w /etc/sudoers.d/       -p wa -k sudoers

-w /root/.ssh/           -p wa -k ssh_keys
-w /home/                -p wa -k ssh_keys

-w /etc/passwd           -p wa -k accounts
-w /etc/shadow           -p wa -k accounts
-w /etc/group            -p wa -k accounts

-a always,exit -F arch=b64 -S init_module   -k module_load
-a always,exit -F arch=b64 -S finit_module  -k module_load
-a always,exit -F arch=b64 -S delete_module -k module_load

-a always,exit -F arch=b64 -S ptrace -k ptrace
-a always,exit -F arch=b64 -S mount   -k mount
-a always,exit -F arch=b64 -S umount2 -k mount

-e 2
AUDIT_EOF

# ─── fail2ban ───
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

# ─── nftables ───
cat > "$CHROOT/etc/nftables.conf" <<'NFT_EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet eiciel {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport 22 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT_EOF

# ─── systemd watcher unit ───
cat > "$CHROOT/etc/systemd/system/eiciel-watch.service" <<'UNIT_EOF'
[Unit]
Description=Eiciel audit watcher (triggers containment)
After=auditd.service
Requires=auditd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/eiciel-watch.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

# ─── Recovery runbook ───
cat > "$CHROOT/root/RECOVERY.md" <<'RECOVERY_EOF'
# Eiciel Server — post-incident recovery runbook

Containment already: preserved evidence, blocked outbound except MGMT_IP,
killed non-admin TTYs, stopped services, posted webhook.

## 0. DO NOT
- Do not power off. RAM holds evidence.
- Do not delete /var/lib/incidents.
- Do not "clean up" the host. Rebuild it.

## 1. Snapshot from hypervisor FIRST
Proxmox:    qm snapshot <vmid> incident-<date>
VMware:     vim-cmd vmsvc/snapshot.create <vmid> incident-<date>
AWS EC2:    aws ec2 create-snapshot --volume-id <vol>
Bare metal: dd if=/dev/sdX of=/mnt/external/incident.img bs=4M status=progress

## 2. SSH from MGMT_IP (still allowed)
ssh admin@<server>

## 3. Copy evidence off-host
sudo cp -a /var/lib/incidents/ /root/incidents-preserved/
rsync -av /root/incidents-preserved/ admin@mgmt-host:/srv/incidents/

## 4. Inspect
cat /var/lib/incidents/*/containment.log
ausearch -k priv_esc    --start today | less
ausearch -k ssh_keys    --start today | less
ausearch -k module_load --start today | less
journalctl -u eiciel-watch --since "2 hours ago"

## 5. Rotate every secret
- rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; re-add only yours
- passwd root; passwd admin
- DB creds; app .env; ~/.aws; cloud tokens; TLS certs

## 6. Rebuild from known-good image

## 7. Lift isolation (only after snapshot + evidence copy)
sudo nft delete table inet eiciel_contain

## 8. Post-mortem
Update /etc/audit/rules.d/eiciel.rules based on what fired.
RECOVERY_EOF
chmod 644 "$CHROOT/root/RECOVERY.md"

# ─── MOTD ───
cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD_EOF'
#!/bin/sh
if [ -t 0 ]; then
  cat <<'BANNER'

  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel Server — containment stack active                ║
  ║                                                          ║
  ║  Config    : /etc/eiciel/config.env                      ║
  ║  Evidence  : /var/lib/incidents/<timestamp>-<pid>/       ║
  ║  Recovery  : /root/RECOVERY.md      ← read after breach  ║
  ║  Dashboard : sudo /usr/local/bin/eiciel-dashboard        ║
  ║                                                          ║
  ║  Manual   : sudo /usr/local/sbin/eiciel-contain.sh       ║
  ║  Lift     : sudo nft delete table inet eiciel_contain    ║
  ╚══════════════════════════════════════════════════════════╝

BANNER
fi
MOTD_EOF
chmod 755 "$CHROOT/etc/profile.d/eiciel-motd.sh"

# ─── authorized_keys ───
if [ -n "$SSH_AUTHORIZED_KEY" ]; then
  echo "$SSH_AUTHORIZED_KEY" > "$CHROOT/root/.ssh/authorized_keys"
  chmod 600 "$CHROOT/root/.ssh/authorized_keys"
  cat > config/hooks/025-authorized-keys.hook.chroot <<'EOF'
#!/bin/bash
set -e
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o admin -g admin /home/admin/.ssh
  cp /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
  chown admin:admin /home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
fi
EOF
  chmod +x config/hooks/025-authorized-keys.hook.chroot
fi

# ─────────────────────────────────────────────────────────────────
# 7. Ship the Electron dashboard (if present)
# ─────────────────────────────────────────────────────────────────
if [ "$SHIP_DASHBOARD" = "1" ]; then
  echo "📦 Staging dashboard into chroot…"
  install -d -m 755 "$CHROOT/opt/eiciel-dashboard"
  cp -a "$APP_DIST/." "$CHROOT/opt/eiciel-dashboard/"
  chmod -R 755 "$CHROOT/opt/eiciel-dashboard"

  cat > config/hooks/035-dashboard.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[035] Installing dashboard launcher…"
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
else
  echo "ℹ️  Dashboard not shipped."
fi

# ─────────────────────────────────────────────────────────────────
# 8. Hook 030 — enable services
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/030-enable-services.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[030] Enabling services…"
systemctl enable auditd
augenrules --load 2>/dev/null || true
systemctl enable fail2ban
systemctl enable nftables
systemctl enable ssh
systemctl enable eiciel-watch
install -d -m 2755 /var/log/journal
systemctl enable systemd-journald
echo "[030] Enabled: auditd fail2ban nftables ssh eiciel-watch"
EOF
chmod +x config/hooks/030-enable-services.hook.chroot

# ─────────────────────────────────────────────────────────────────
# 9. Hook 040 — verify
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/040-verify.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[040] Verifying install…"
fail=0
for f in /usr/local/sbin/eiciel-contain.sh \
         /usr/local/sbin/eiciel-watch.sh \
         /etc/eiciel/config.env \
         /etc/audit/rules.d/eiciel.rules \
         /etc/fail2ban/jail.d/eiciel.local \
         /etc/nftables.conf \
         /etc/systemd/system/eiciel-watch.service \
         /root/RECOVERY.md \
         /etc/profile.d/eiciel-motd.sh; do
  if [ ! -e "$f" ]; then
    echo "  ❌ missing: $f"
    fail=1
  fi
done
[ -x /usr/local/sbin/eiciel-contain.sh ] || { echo "  ❌ contain not executable"; fail=1; }
[ -x /usr/local/sbin/eiciel-watch.sh ]   || { echo "  ❌ watch not executable";   fail=1; }
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || { echo "  ❌ config.env mode wrong"; fail=1; }

if [ -x /opt/eiciel-dashboard/EicielDashboard ]; then
  echo "  ✅ dashboard present"
fi

[ "$fail" -eq 0 ] || exit 1
echo "[040] All checks passed."
EOF
chmod +x config/hooks/040-verify.hook.chroot

# ─────────────────────────────────────────────────────────────────
# 10. Hook 060 — cleanup
# ─────────────────────────────────────────────────────────────────
cat > config/hooks/060-cleanup.hook.chroot <<'EOF'
#!/bin/bash
set -e
echo "[060] Cleanup…"
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
chmod 644 /root/RECOVERY.md
chmod 755 /usr/local/sbin/eiciel-contain.sh
chmod 755 /usr/local/sbin/eiciel-watch.sh
chmod 600 /etc/eiciel/config.env
EOF
chmod +x config/hooks/060-cleanup.hook.chroot

chmod +x config/hooks/*.hook.chroot

# ─────────────────────────────────────────────────────────────────
# 11. Package list
# ─────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────
# 12. Static chroot files
# ─────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────
# 13. GRUB menu
# ─────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────
# 14. Build
# ─────────────────────────────────────────────────────────────────
echo "📦 Configuring live-build…"
./auto/config

echo "📦 Running debootstrap…"
lb bootstrap 2>&1 | tee bootstrap.log

if [ ! -x "chroot/bin/sh" ] || [ ! -x "chroot/usr/bin/env" ]; then
  echo "❌ Bootstrap failed. Last 40 lines:"
  tail -40 bootstrap.log
  exit 1
fi
echo "✅ chroot/ created."

echo "📦 Running chroot stage…"
lb chroot 2>&1 | tee chroot.log

echo "📦 Running binary stage…"
lb binary 2>&1 | tee binary.log

# ─────────────────────────────────────────────────────────────────
# 15. Report
# ─────────────────────────────────────────────────────────────────
ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
if [ -z "$ISO" ]; then
  echo "❌ No ISO produced. Check binary.log."
  exit 1
fi

if [ "$ISO" != "${ISO_NAME}.iso" ]; then
  mv "$ISO" "${ISO_NAME}.iso"
  ISO="${ISO_NAME}.iso"
fi

SIZE=$(du -h "$ISO" | cut -f1)

cat <<EOF

═══════════════════════════════════════════════════════════════
✅  Done!  $ROOT/$ISO   ($SIZE)
═══════════════════════════════════════════════════════════════

Flash to USB:
    sudo dd if=$ISO of=/dev/sdX bs=4M status=progress oflag=sync

Test in QEMU:
    qemu-system-x86_64 -m 4096 -cdrom $ISO -boot d

On first boot:
    - Login as 'admin' (SSH key only)
    - Read /root/RECOVERY.md
    - Verify:  systemctl status auditd fail2ban nftables ssh eiciel-watch
    - Test:    sudo /usr/local/sbin/eiciel-contain.sh
    - Lift:    sudo nft delete table inet eiciel_contain
EOF

if [ "$SHIP_DASHBOARD" = "1" ]; then
  cat <<EOF
    - Dashboard (from an X-forwarded SSH session):
          ssh -X admin@<server>
          sudo /usr/local/bin/eiciel-dashboard
EOF
fi
