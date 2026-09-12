#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel Server ISO — containment edition (patched)
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHROOT="config/includes.chroot"
APP_DIST="$ROOT/eiciel-app-dist/EicielDashboard-linux-x64"
DAEMON_DIST="$ROOT/eiciel-app-dist/eicield"

# ── PATCH: no unsafe defaults. Require an explicit local config. ──
CONFIG_LOCAL="$ROOT/config/config.local.env"
if [ ! -f "$CONFIG_LOCAL" ]; then
  echo "❌ Missing $CONFIG_LOCAL"
  echo "   Copy config/config.local.env.example and fill in MGMT_IP, WEBHOOK_URL."
  exit 1
fi

# Parse config.local.env as data (never source it — spaces in values are legal).
while IFS='=' read -r _key _value || [ -n "$_key" ]; do
    # trim leading/trailing whitespace from key
    _key="${_key#"${_key%%[![:space:]]*}"}"
    _key="${_key%"${_key##*[![:space:]]}"}"
    case "$_key" in
        ''|\#*) continue ;;   # blank line or comment
    esac
    # trim leading whitespace from value
    _value="${_value#"${_value%%[![:space:]]*}"}"
    # strip one layer of matching quotes if present
    case "$_value" in
        \"*\") _value="${_value#\"}"; _value="${_value%\"}" ;;
        \'*\') _value="${_value#\'}"; _value="${_value%\'}" ;;
    esac
    export "$_key=$_value"
done < "$CONFIG_LOCAL"

: "${MGMT_IP:?set MGMT_IP in config.local.env}"
: "${WEBHOOK_URL:?set WEBHOOK_URL in config.local.env}"

# ── PATCH: refuse public ntfy.sh unless explicitly allowed ──
case "$WEBHOOK_URL" in
  https://ntfy.sh/*)
    if [ "${ALLOW_PUBLIC_NTFY:-0}" != "1" ]; then
      echo "❌ WEBHOOK_URL points to public ntfy.sh. Set ALLOW_PUBLIC_NTFY=1 to override."
      exit 1
    fi ;;
esac

STOP_SERVICES="${STOP_SERVICES:-sshd nginx apache2 postgresql mysql mariadb redis-server docker}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-0}"
INCLUDE_DASHBOARD="${INCLUDE_DASHBOARD:-auto}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-600}"
HOSTNAME_NEW="${HOSTNAME_NEW:-eiciel-srv}"

echo "  MGMT_IP       = $MGMT_IP"
echo "  WEBHOOK_URL   = $WEBHOOK_URL"
echo "  STOP_SERVICES = $STOP_SERVICES"

[[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }

for cmd in lb debootstrap xorriso mksquashfs; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Missing tool: $cmd"; exit 1; }
done

SHIP_DASHBOARD=0
case "$INCLUDE_DASHBOARD" in
  1) SHIP_DASHBOARD=1 ;;
  0) SHIP_DASHBOARD=0 ;;
  auto) [ -d "$APP_DIST" ] && SHIP_DASHBOARD=1 ;;
  *) echo "❌ INCLUDE_DASHBOARD must be auto|0|1"; exit 1 ;;
esac
if [ "$SHIP_DASHBOARD" = "1" ]; then
  [ -d "$APP_DIST" ]    || { echo "❌ $APP_DIST missing — run build-eiciel-app.sh"; exit 1; }
  [ -d "$DAEMON_DIST" ] || { echo "❌ $DAEMON_DIST missing — run build-eiciel-app.sh"; exit 1; }
fi

echo "📦 Cleaning old build state…"
lb clean --purge >/dev/null 2>&1 || true
rm -rf config auto chroot binary cache .build local bootstrap.log chroot.log binary.log 2>/dev/null || true

mkdir -p auto config/hooks config/package-lists config/bootloaders/grub \
         config/includes.chroot/etc/eiciel \
         config/includes.chroot/etc/audit/rules.d \
         config/includes.chroot/etc/fail2ban/jail.d \
         config/includes.chroot/etc/systemd/system \
         config/includes.chroot/etc/ssh/sshd_config.d \
         config/includes.chroot/etc/profile.d \
         config/includes.chroot/usr/local/sbin \
         config/includes.chroot/root/.ssh \
         config/includes.chroot/var/lib/incidents

# ── auto/config (unchanged) ──
BOOTAPPEND="boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}"
[ "$ENABLE_PERSISTENCE" = "1" ] && BOOTAPPEND="$BOOTAPPEND persistence persistence-storage=filesystem"

cat > auto/config <<EOF
#!/bin/bash
set -e
lb config noauto \\
  --mode debian --distribution bookworm --architectures amd64 \\
  --binary-images iso-hybrid \\
  --archive-areas "main contrib non-free non-free-firmware" \\
  --bootappend-live "$BOOTAPPEND" \\
  --linux-flavours amd64 --debian-installer none --memtest none \\
  --iso-application "Eiciel Server" --iso-publisher "Eiciel" --iso-volume "EICIEL_SRV" \\
  --apt-options "--yes --no-install-recommends" --apt-indices false --apt-recommends false \\
  --firmware-binary false --firmware-chroot true \\
  --initramfs live-boot --compression xz \\
  --bootloader "grub-efi grub-pc" --system live --initsystem systemd \\
  --mirror-bootstrap "http://deb.debian.org/debian/" \\
  --mirror-chroot "http://deb.debian.org/debian/" \\
  --mirror-chroot-security "http://security.debian.org/debian-security/" \\
  --mirror-binary "http://deb.debian.org/debian/" \\
  --mirror-binary-security "http://security.debian.org/debian-security/"
EOF
chmod +x auto/config

# ── Hook 005 — apt sources (unchanged) ──
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

# ── Hook 010 — sshd (unchanged) ──
cat > config/hooks/010-ssh.hook.chroot <<'EOF'
#!/bin/bash
set -e
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-eiciel.conf <<'EOSSH'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
EOSSH
systemctl enable ssh
EOF

# ── PATCH Hook 020 — admin user WITHOUT NOPASSWD:ALL ──
cat > config/hooks/020-users.hook.chroot <<'EOF'
#!/bin/bash
set -e
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo admin
  passwd -l admin
fi
install -d -m 700 -o admin -g admin /home/admin/.ssh

# admin requires a password for sudo. No blanket NOPASSWD.
cat > /etc/sudoers.d/admin <<'SUDO'
admin ALL=(ALL:ALL) ALL
SUDO
chmod 440 /etc/sudoers.d/admin
EOF

# ── PATCH: daemon group + user ──
cat > config/hooks/021-eiciel-daemon-user.hook.chroot <<'EOF'
#!/bin/bash
set -e
getent group eiciel >/dev/null || groupadd --system eiciel
id -u eiciel >/dev/null 2>&1 || \
  useradd --system --gid eiciel --home-dir /var/lib/eiciel --create-home --shell /usr/sbin/nologin eiciel
usermod -aG eiciel admin
EOF
chmod +x config/hooks/021-eiciel-daemon-user.hook.chroot

# ── Config file (still 600; contents from config.local.env) ──
cat > "$CHROOT/etc/eiciel/config.env" <<EOF
MGMT_IP="$MGMT_IP"
WEBHOOK_URL="$WEBHOOK_URL"
STOP_SERVICES="$STOP_SERVICES"
INCIDENT_ROOT="/var/lib/incidents"
COOLDOWN_SECONDS=$COOLDOWN_SECONDS
# RESTIC_REPO="s3:https://s3.amazonaws.com/your-bucket/incidents"
# RESTIC_PASSWORD_FILE="/etc/eiciel/restic.pass"
EOF
chmod 600 "$CHROOT/etc/eiciel/config.env"

# ─────────────────────────────────────────────────────────────────
#  Containment script — PATCHED
#  * resolves webhook + restic hostnames up front
#  * allows those IPs in nft output so notify/push actually work
#  * real restic password-file check
# ─────────────────────────────────────────────────────────────────
cat > "$CHROOT/usr/local/sbin/eiciel-contain.sh" <<'CONTAIN_EOF'
#!/bin/bash
# Preserve → isolate → notify. Never destroy.
set -euo pipefail
source /etc/eiciel/config.env

INCIDENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCIDENT_DIR="$INCIDENT_ROOT/$INCIDENT_ID"
mkdir -p "$INCIDENT_DIR"; chmod 700 "$INCIDENT_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$INCIDENT_DIR/containment.log" >&2; }
log "=== Incident $INCIDENT_ID starting ==="
log "Host: $(hostname)  Kernel: $(uname -r)"

# ── Resolve allow-list IPs BEFORE we tighten egress ──
resolve_host() {
  local url="$1"
  [ -n "$url" ] || return 0
  local host
  host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
}
ALLOW_IPS=()
if [ -n "${WEBHOOK_URL:-}" ]; then
  while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$WEBHOOK_URL")
fi
if [ -n "${RESTIC_REPO:-}" ]; then
  while read -r ip; do [ -n "$ip" ] && ALLOW_IPS+=("$ip"); done < <(resolve_host "$RESTIC_REPO")
fi
log "Resolved allow-list: ${ALLOW_IPS[*]:-none}"

# ── 1. PRESERVE EVIDENCE ──
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

for f in /var/log/auth.log /var/log/syslog /var/log/secure /var/log/messages \
         /var/log/kern.log /var/log/nginx/access.log /var/log/nginx/error.log \
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

# ── 2. ISOLATE NETWORK (allow-list includes webhook + restic) ──
log "Isolating network (MGMT_IP=$MGMT_IP)…"
nft delete table inet eiciel_contain 2>/dev/null || true
nft add table inet eiciel_contain
nft add chain inet eiciel_contain output '{ type filter hook output priority -10; policy drop; }'
nft add rule inet eiciel_contain output oif lo accept
nft add rule inet eiciel_contain output ct state established,related accept
nft add rule inet eiciel_contain output udp dport 53 accept
nft add rule inet eiciel_contain output tcp dport 53 accept
nft add rule inet eiciel_contain output ip daddr "$MGMT_IP" accept
for ip in "${ALLOW_IPS[@]:-}"; do
  [ -n "$ip" ] && nft add rule inet eiciel_contain output ip daddr "$ip" accept
done
log "Outbound locked."

# ── 3. KILL ATTACKER SESSIONS ──
log "Terminating non-admin TTY sessions…"
while read -r user tty _; do
  [ -z "${user:-}" ] && continue
  [ "$user" = "root" ] && continue
  [ "$user" = "admin" ] && continue
  case "$tty" in /dev/tty*|/dev/pts/*) ;; *) continue ;; esac
  log "  killing user=$user tty=$tty"
  pkill -9 -t "${tty#/dev/}" 2>/dev/null || true
done < <(who)

# ── 4. STOP EXPOSED SERVICES ──
for svc in $STOP_SERVICES; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "Stopping $svc"
    systemctl stop "$svc" 2>/dev/null || true
  fi
done

# ── 5. PUSH OFF-HOST (PATCHED condition) ──
if [ -n "${RESTIC_REPO:-}" ] \
   && [ -n "${RESTIC_PASSWORD_FILE:-}" ] \
   && [ -f "$RESTIC_PASSWORD_FILE" ]; then
  log "Pushing incident to $RESTIC_REPO ..."
  if restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
       backup "$INCIDENT_DIR" >/dev/null 2>&1; then
    log "restic backup ok"
  else
    log "restic backup FAILED"
  fi
fi

# ── 6. NOTIFY ──
if [ -n "${WEBHOOK_URL:-}" ]; then
  payload=$(jq -nc \
    --arg inc "$INCIDENT_ID" --arg host "$(hostname)" \
    --arg time "$(date -u +%FT%TZ)" --arg dir "$INCIDENT_DIR" --arg svc "$STOP_SERVICES" \
    '{incident:$inc,host:$host,time:$time,dir:$dir,services_stopped:$svc}')
  if curl -fsS --max-time 10 -X POST "$WEBHOOK_URL" \
       -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
    log "webhook ok"
  else
    log "webhook FAILED"
  fi
fi

logger -t eiciel "CONTAINMENT COMPLETE — incident $INCIDENT_ID — evidence in $INCIDENT_DIR"
log "=== Containment complete ==="
echo "$INCIDENT_DIR"
CONTAIN_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-contain.sh"

# ── PATCH: Watcher — follow journald, parse via ausearch, race-free ──
cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

LOCK="/run/eiciel-contain.lock"
COOLDOWN="${COOLDOWN_SECONDS:-600}"
KEYS='priv_esc|priv_esc_unset|sudoers|ssh_keys|module_load|ptrace|mount'

logger -t eiciel "watch: starting (journalctl -f -u auditd)"

# Use auditd's journald stream, which rotates safely.
journalctl -f -u auditd -o cat --no-pager 2>/dev/null | while read -r line; do
  case "$line" in
    *"key=\"priv_esc"*|*"key=\"sudoers"*|*"key=\"ssh_keys"*|*"key=\"module_load"*|*"key=\"ptrace"*|*"key=\"mount"*) ;;
    *) continue ;;
  esac
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

# ── audit rules (unchanged) ──
cat > "$CHROOT/etc/audit/rules.d/eiciel.rules" <<'AUDIT_EOF'
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -k priv_esc
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid=4294967295 -k priv_esc_unset
-w /etc/sudoers    -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /root/.ssh/     -p wa -k ssh_keys
-w /home/          -p wa -k ssh_keys
-w /etc/passwd     -p wa -k accounts
-w /etc/shadow     -p wa -k accounts
-w /etc/group      -p wa -k accounts
-a always,exit -F arch=b64 -S init_module   -k module_load
-a always,exit -F arch=b64 -S finit_module  -k module_load
-a always,exit -F arch=b64 -S delete_module -k module_load
-a always,exit -F arch=b64 -S ptrace -k ptrace
-a always,exit -F arch=b64 -S mount   -k mount
-a always,exit -F arch=b64 -S umount2 -k mount
-e 2
AUDIT_EOF

# ── fail2ban (unchanged) ──
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

# ── nftables default (unchanged) ──
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
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
NFT_EOF

# ── watcher unit (unchanged) ──
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

# ── Recovery runbook (unchanged) ──
cat > "$CHROOT/root/RECOVERY.md" <<'RECOVERY_EOF'
# Eiciel Server — post-incident recovery runbook

## 0. DO NOT
- Do not power off.
- Do not delete /var/lib/incidents.
- Do not "clean up". Rebuild.

## 1. Snapshot the hypervisor FIRST
Proxmox:  qm snapshot <vmid> incident-<date>
VMware:   vim-cmd vmsvc/snapshot.create <vmid> incident-<date>
AWS EC2:  aws ec2 create-snapshot --volume-id <vol>

## 2. SSH from MGMT_IP
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

## 7. Lift isolation
sudo nft delete table inet eiciel_contain

## 8. Post-mortem
RECOVERY_EOF
chmod 644 "$CHROOT/root/RECOVERY.md"

# ── MOTD (unchanged) ──
cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD_EOF'
#!/bin/sh
if [ -t 0 ]; then
  cat <<'BANNER'

  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel Server — containment stack active                ║
  ║                                                          ║
  ║  Config    : /etc/eiciel/config.env                      ║
  ║  Evidence  : /var/lib/incidents/<timestamp>-<pid>/       ║
  ║  Recovery  : /root/RECOVERY.md                           ║
  ║  Dashboard : ssh -X admin@<host>                         ║
  ║              sudo -u eiciel /usr/local/bin/eiciel-dashboard
  ║  Manual    : sudo /usr/local/sbin/eiciel-contain.sh      ║
  ║  Lift      : sudo nft delete table inet eiciel_contain   ║
  ╚══════════════════════════════════════════════════════════╝

BANNER
fi
MOTD_EOF
chmod 755 "$CHROOT/etc/profile.d/eiciel-motd.sh"

# ── authorized_keys (unchanged) ──
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
#  Dashboard + daemon — PATCHED install
# ─────────────────────────────────────────────────────────────────
if [ "$SHIP_DASHBOARD" = "1" ]; then
  install -d -m 755 "$CHROOT/opt/eiciel-dashboard"
  cp -a "$APP_DIST/." "$CHROOT/opt/eiciel-dashboard/"
  chmod -R 755 "$CHROOT/opt/eiciel-dashboard"

  install -d -m 755 "$CHROOT/usr/local/lib/eicield"
  install -m 755 "$DAEMON_DIST/eicield.py"          "$CHROOT/usr/local/lib/eicield/eicield.py"
  install -m 644 "$DAEMON_DIST/eicield.service"     "$CHROOT/etc/systemd/system/eicield.service"

  # Launcher runs as the unprivileged eiciel user, sandbox on.
  cat > "$CHROOT/usr/local/bin/eiciel-dashboard" <<'LAUNCH'
#!/bin/bash
exec sudo -u eiciel -H /opt/eiciel-dashboard/EicielDashboard "$@"
LAUNCH
  chmod 755 "$CHROOT/usr/local/bin/eiciel-dashboard"
fi

# ── Hook 030 — enable services ──
cat > config/hooks/030-enable-services.hook.chroot <<'EOF'
#!/bin/bash
set -e
systemctl enable auditd
augenrules --load 2>/dev/null || true
systemctl enable fail2ban
systemctl enable nftables
systemctl enable ssh
systemctl enable eiciel-watch
systemctl enable eicield.service
install -d -m 2755 /var/log/journal
systemctl enable systemd-journald
EOF
chmod +x config/hooks/030-enable-services.hook.chroot

# ── Hook 040 — verify ──
cat > config/hooks/040-verify.hook.chroot <<'EOF'
#!/bin/bash
set -e
fail=0
for f in /usr/local/sbin/eiciel-contain.sh \
         /usr/local/sbin/eiciel-watch.sh \
         /etc/eiciel/config.env \
         /etc/audit/rules.d/eiciel.rules \
         /etc/fail2ban/jail.d/eiciel.local \
         /etc/nftables.conf \
         /etc/systemd/system/eiciel-watch.service \
         /etc/systemd/system/eicield.service \
         /usr/local/lib/eicield/eicield.py \
         /root/RECOVERY.md \
         /etc/profile.d/eiciel-motd.sh; do
  [ -e "$f" ] || { echo "  ❌ missing: $f"; fail=1; }
done
[ -x /usr/local/sbin/eiciel-contain.sh ] || { echo "  ❌ contain not executable"; fail=1; }
[ -x /usr/local/sbin/eiciel-watch.sh ]   || { echo "  ❌ watch not executable";   fail=1; }
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || { echo "  ❌ config.env mode wrong"; fail=1; }

# admin must NOT have NOPASSWD:ALL
if grep -rqE 'NOPASSWD:\s*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
  echo "  ❌ NOPASSWD:ALL present in sudoers"; fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "[040] All checks passed."
EOF
chmod +x config/hooks/040-verify.hook.chroot

# ── Hook 060 — cleanup (unchanged) ──
cat > config/hooks/060-cleanup.hook.chroot <<'EOF'
#!/bin/bash
set -e
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

# ── package list (add python3) ──
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
python3

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

# ── static chroot files (unchanged) ──
echo "$HOSTNAME_NEW" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_NEW
::1         localhost ip6-localhost ip6-loopback
EOF

# ── GRUB (unchanged) ──
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

# ── Build ──
./auto/config
lb bootstrap 2>&1 | tee bootstrap.log
lb chroot    2>&1 | tee chroot.log
lb binary    2>&1 | tee binary.log

ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
[ -n "$ISO" ] || { echo "❌ No ISO produced."; exit 1; }
[ "$ISO" = "eiciel-server.iso" ] || { mv "$ISO" eiciel-server.iso; ISO="eiciel-server.iso"; }

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅  Done!  $ROOT/$ISO   ($(du -h "$ISO" | cut -f1))"
echo "═══════════════════════════════════════════════════════════════"