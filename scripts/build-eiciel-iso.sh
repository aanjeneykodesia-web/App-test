#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Eiciel Server ISO — containment edition + license gate
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CHROOT="config/includes.chroot"
APP_DIST="$ROOT/eiciel-app-dist/EicielDashboard-linux-x64"
DAEMON_DIST="$ROOT/eiciel-app-dist/eicield"

# ── Config loading (parse, never source) ──
CONFIG_LOCAL="$ROOT/config/config.local.env"
if [ ! -f "$CONFIG_LOCAL" ]; then
  echo "❌ Missing $CONFIG_LOCAL"
  echo "   Copy config/config.local.env.example and fill in MGMT_IP, WEBHOOK_URL."
  exit 1
fi

while IFS='=' read -r _key _value || [ -n "$_key" ]; do
    _key="${_key#"${_key%%[![:space:]]*}"}"
    _key="${_key%"${_key##*[![:space:]]}"}"
    case "$_key" in
        ''|\#*) continue ;;
    esac
    _value="${_value#"${_value%%[![:space:]]*}"}"
    case "$_value" in
        \"*\") _value="${_value#\"}"; _value="${_value%\"}" ;;
        \'*\') _value="${_value#\'}"; _value="${_value%\'}" ;;
    esac
    export "$_key=$_value"
done < "$CONFIG_LOCAL"

: "${MGMT_IP:?set MGMT_IP in config.local.env}"
: "${WEBHOOK_URL:?set WEBHOOK_URL in config.local.env}"

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
BUILD_MODE="${BUILD_MODE:-install}"
export BUILD_MODE

# ── License configuration ──
LICENSE_GATE_MODE="${LICENSE_GATE_MODE:-none}"     # none | soft | hard
LICENSE_PUBKEY_FILE="${LICENSE_PUBKEY_FILE:-}"     # path to license-pub.pem
export LICENSE_GATE_MODE

echo "  MGMT_IP         = $MGMT_IP"
echo "  WEBHOOK_URL     = $WEBHOOK_URL"
echo "  STOP_SERVICES   = $STOP_SERVICES"
echo "  BUILD_MODE      = $BUILD_MODE"
echo "  PERSISTENCE     = $ENABLE_PERSISTENCE"
echo "  LICENSE_GATE    = $LICENSE_GATE_MODE"
[ "$LICENSE_GATE_MODE" != "none" ] && echo "  LICENSE_PUBKEY  = $LICENSE_PUBKEY_FILE"

[[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }

for cmd in lb debootstrap xorriso mksquashfs; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Missing tool: $cmd"; exit 1; }
done

if [ "$LICENSE_GATE_MODE" != "none" ]; then
  case "$LICENSE_GATE_MODE" in
    soft|hard) ;;
    *) echo "❌ LICENSE_GATE_MODE must be none|soft|hard"; exit 1 ;;
  esac
  if [ -z "$LICENSE_PUBKEY_FILE" ] || [ ! -f "$LICENSE_PUBKEY_FILE" ]; then
    echo "❌ LICENSE_GATE_MODE=$LICENSE_GATE_MODE requires LICENSE_PUBKEY_FILE to point at an existing file"
    exit 1
  fi
  command -v openssl >/dev/null || { echo "❌ openssl not found on build host"; exit 1; }
fi

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
         config/includes.installer \
         config/includes.chroot/etc/eiciel \
         config/includes.chroot/etc/audit/rules.d \
         config/includes.chroot/etc/fail2ban/jail.d \
         config/includes.chroot/etc/systemd/system \
         config/includes.chroot/etc/ssh/sshd_config.d \
         config/includes.chroot/etc/profile.d \
         config/includes.chroot/usr/local/sbin \
         config/includes.chroot/usr/local/bin \
         config/includes.chroot/root/.ssh \
         config/includes.chroot/var/lib/incidents

# ── auto/config ──
BOOTAPPEND="boot=live components quiet loglevel=3 username=admin hostname=${HOSTNAME_NEW}"
[ "$ENABLE_PERSISTENCE" = "1" ] && BOOTAPPEND="$BOOTAPPEND persistence persistence-storage=filesystem"

if [ "$BUILD_MODE" = "install" ]; then
  INSTALLER_OPT="live"
else
  INSTALLER_OPT="none"
fi

cat > auto/config <<EOF
#!/bin/bash
set -e
lb config noauto \\
  --mode debian --distribution bookworm --architectures amd64 \\
  --binary-images iso-hybrid \\
  --archive-areas "main contrib non-free non-free-firmware" \\
  --bootappend-live "$BOOTAPPEND" \\
  --linux-flavours amd64 --debian-installer $INSTALLER_OPT --memtest none \\
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

# ── Hook 005 — apt sources ──
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

# ── Hook 006 — sysctl hardening ──
cat > config/hooks/006-sysctl.hook.chroot <<'EOF'
#!/bin/bash
set -e
install -d -m 755 /etc/sysctl.d
cat > /etc/sysctl.d/99-eiciel.conf <<'SYSCTL'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
SYSCTL
EOF
chmod +x config/hooks/006-sysctl.hook.chroot

# ── Hook 010 — sshd ──
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

# ── Hook 020 — admin user ──
cat > config/hooks/020-users.hook.chroot <<'EOF'
#!/bin/bash
set -e
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo admin
  if [ "${BUILD_MODE:-live}" = "live" ]; then
    passwd -l admin
  fi
fi
install -d -m 700 -o admin -g admin /home/admin/.ssh
cat > /etc/sudoers.d/admin <<'SUDO'
admin ALL=(ALL:ALL) ALL
SUDO
chmod 440 /etc/sudoers.d/admin
EOF

# ── Hook 021 — daemon group + user ──
cat > config/hooks/021-eiciel-daemon-user.hook.chroot <<'EOF'
#!/bin/bash
set -e
getent group eiciel >/dev/null || groupadd --system eiciel
id -u eiciel >/dev/null 2>&1 || \
  useradd --system --gid eiciel --home-dir /var/lib/eiciel --create-home --shell /usr/sbin/nologin eiciel
usermod -aG eiciel admin
EOF
chmod +x config/hooks/021-eiciel-daemon-user.hook.chroot

# ── Config file ──
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

# ═════════════════════════════════════════════════════════════════
#  LICENSE GATE
# ═════════════════════════════════════════════════════════════════
if [ "$LICENSE_GATE_MODE" != "none" ]; then

  install -m 644 "$LICENSE_PUBKEY_FILE" "$CHROOT/etc/eiciel/license.pub"
  echo "  license pubkey sha256: $(sha256sum "$LICENSE_PUBKEY_FILE" | cut -c1-16)…"

  # ── license check ──
  cat > "$CHROOT/usr/local/sbin/eiciel-license-check" <<'LICCHK_EOF'
#!/bin/bash
# Verify the Eiciel license. Exit 0 = valid, non-zero = invalid.
set -euo pipefail

PUBKEY="/etc/eiciel/license.pub"
LICENSE_JSON="/etc/eiciel/license.json"
LICENSE_SIG="/etc/eiciel/license.sig"
LICENSE_LABEL="EICIEL_LIC"

log() { logger -t eiciel-license "$*"; echo "[license] $*" >&2; }

# If license files aren't present, try to fetch from a labeled USB/partition.
if [ ! -f "$LICENSE_JSON" ] || [ ! -f "$LICENSE_SIG" ]; then
  lic_dev="$(blkid -L "$LICENSE_LABEL" 2>/dev/null || true)"
  if [ -n "$lic_dev" ]; then
    tmp="$(mktemp -d)"
    if mount -o ro "$lic_dev" "$tmp" 2>/dev/null; then
      [ -f "$tmp/license.json" ] && install -m 600 "$tmp/license.json" "$LICENSE_JSON"
      [ -f "$tmp/license.sig" ]  && install -m 600 "$tmp/license.sig"  "$LICENSE_SIG"
      umount "$tmp" 2>/dev/null || true
    fi
    rmdir "$tmp" 2>/dev/null || true
  fi
fi

[ -f "$PUBKEY" ]       || { log "pubkey missing"; exit 1; }
[ -f "$LICENSE_JSON" ] || { log "license.json not found"; exit 1; }
[ -f "$LICENSE_SIG" ]  || { log "license.sig not found"; exit 1; }

# Ed25519 raw signature verification.
if ! openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
       -in "$LICENSE_JSON" -sigfile "$LICENSE_SIG" >/dev/null 2>&1; then
  log "signature verification FAILED"
  exit 1
fi

# Time window.
now="$(date -u +%s)"
not_before="$(jq -r '.not_before' "$LICENSE_JSON")"
not_after="$(jq -r '.not_after'  "$LICENSE_JSON")"
nb_epoch="$(date -u -d "$not_before" +%s 2>/dev/null || echo 0)"
na_epoch="$(date -u -d "$not_after"  +%s 2>/dev/null || echo 0)"

[ "$now" -ge "$nb_epoch" ] || { log "license not yet valid (before $not_before)"; exit 1; }
[ "$now" -le "$na_epoch" ] || { log "license expired on $not_after"; exit 1; }

# Optional hardware binding.
expected_mid="$(jq -r '.machine_id // empty' "$LICENSE_JSON")"
if [ -n "$expected_mid" ]; then
  actual_mid="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr 'A-Z' 'a-z' || true)"
  if [ "$expected_mid" != "$actual_mid" ]; then
    log "license bound to a different machine (want=$expected_mid got=$actual_mid)"
    exit 1
  fi
fi

log "license OK ($(jq -r .license_id "$LICENSE_JSON"))"
exit 0
LICCHK_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-check"

  # ── license gate ──
  cat > "$CHROOT/usr/local/sbin/eiciel-license-gate" <<'LICGATE_EOF'
#!/bin/bash
# Early-boot license evaluation. Creates /run/eiciel-licensed on success.
set -euo pipefail
rm -f /run/eiciel-licensed /run/eiciel-unlicensed
if /usr/local/sbin/eiciel-license-check; then
  touch /run/eiciel-licensed
  echo "licensed" > /run/eiciel-license-state
else
  touch /run/eiciel-unlicensed
  echo "unlicensed" > /run/eiciel-license-state
  logger -t eiciel-license "system running UNLICENSED — productive services disabled"
fi
exit 0
LICGATE_EOF
  chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-gate"

  # ── license install utility ──
  cat > "$CHROOT/usr/local/bin/eiciel-license-install" <<'LICINST_EOF'
#!/bin/bash
# Install a license from a file pair or stdin.
# Usage:
#   eiciel-license-install <license.json> <license.sig>
#   cat license.json | eiciel-license-install - <license.sig>
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }
[ "$#" -eq 2 ] || { echo "usage: $0 <license.json|-> <license.sig>"; exit 2; }

SRC_JSON="$1"; SRC_SIG="$2"
install -d -m 755 /etc/eiciel

if [ "$SRC_JSON" = "-" ]; then
  cat > /etc/eiciel/license.json
  chmod 600 /etc/eiciel/license.json
else
  install -m 600 "$SRC_JSON" /etc/eiciel/license.json
fi
install -m 600 "$SRC_SIG" /etc/eiciel/license.sig

if /usr/local/sbin/eiciel-license-check; then
  echo "✅ License installed and verified."
  echo "   Rebooting in 5 seconds…"
  sleep 5
  systemctl reboot
else
  echo "❌ License rejected. See: journalctl -t eiciel-license"
  rm -f /etc/eiciel/license.json /etc/eiciel/license.sig
  exit 1
fi
LICINST_EOF
  chmod 755 "$CHROOT/usr/local/bin/eiciel-license-install"

  # ── systemd gate unit ──
  cat > "$CHROOT/etc/systemd/system/eiciel-license-gate.service" <<'GATE_UNIT'
[Unit]
Description=Eiciel license gate
DefaultDependencies=no
Before=sysinit.target basic.target
After=local-fs.target systemd-remount-fs.service
ConditionPathExists=/etc/eiciel/license.pub

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/eiciel-license-gate

[Install]
WantedBy=sysinit.target
GATE_UNIT

  # ── hard mode lock ──
  if [ "$LICENSE_GATE_MODE" = "hard" ]; then
    cat > "$CHROOT/usr/local/sbin/eiciel-license-hard-lock" <<'HARD_EOF'
#!/bin/bash
set -euo pipefail
sleep 3
if [ ! -f /run/eiciel-licensed ]; then
  logger -t eiciel-license "HARD LOCK — no valid license; isolating system"
  systemctl isolate emergency.target || true
fi
HARD_EOF
    chmod 755 "$CHROOT/usr/local/sbin/eiciel-license-hard-lock"

    cat > "$CHROOT/etc/systemd/system/eiciel-license-hard-lock.service" <<'HARD_UNIT'
[Unit]
Description=Eiciel license hard lock
After=eiciel-license-gate.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eiciel-license-hard-lock

[Install]
WantedBy=multi-user.target
HARD_UNIT
  fi

fi
# ═════════════════════════════════════════════════════════════════
#  END LICENSE GATE
# ═════════════════════════════════════════════════════════════════

# ── Containment script ──
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

if [ -n "${ISOLATION_TIMEOUT:-}" ] && [ "${ISOLATION_TIMEOUT}" -gt 0 ] 2>/dev/null; then
  log "Scheduling auto-lift in ${ISOLATION_TIMEOUT}s"
  systemd-run --on-active="${ISOLATION_TIMEOUT}s" \
              --unit=eiciel-autolift \
              --description="Eiciel auto-lift for $INCIDENT_ID" \
              /usr/sbin/nft delete table inet eiciel_contain \
    || log "WARNING: failed to schedule auto-lift"
fi

log "Terminating non-admin TTY sessions…"
while read -r user tty _; do
  [ -z "${user:-}" ] && continue
  [ "$user" = "root" ] && continue
  [ "$user" = "admin" ] && continue
  case "$tty" in /dev/tty*|/dev/pts/*) ;; *) continue ;; esac
  log "  killing user=$user tty=$tty"
  pkill -9 -t "${tty#/dev/}" 2>/dev/null || true
done < <(who)

for svc in $STOP_SERVICES; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "Stopping $svc"
    systemctl stop "$svc" 2>/dev/null || true
  fi
done

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

# ── Watcher (dual-source) ──
cat > "$CHROOT/usr/local/sbin/eiciel-watch.sh" <<'WATCH_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env

LOCK="/run/eiciel-contain.lock"
COOLDOWN="${COOLDOWN_SECONDS:-600}"

logger -t eiciel "watch: starting (audit.log + journald fallback)"

handle_line() {
  local line="$1"
  case "$line" in
    *"key=\"priv_esc_unset"*|*"key=\"sudoers"*|*"key=\"module_load"*|\
    *"key=\"ptrace"*|*"key=\"watcher_tamper"*) ;;
    *) return 0 ;;
  esac
  if [ -f "$LOCK" ]; then
    local last now
    last=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -lt "$COOLDOWN" ] && return 0
  fi
  touch "$LOCK"
  logger -t eiciel "watch: triggered by audit event"
  /usr/local/sbin/eiciel-contain.sh >>/var/log/eiciel-contain.log 2>&1 || \
    logger -t eiciel "watch: containment FAILED"
}
export -f handle_line

if [ -f /var/log/audit/audit.log ]; then
  tail -F -n0 /var/log/audit/audit.log 2>/dev/null | while read -r line; do
    handle_line "$line"
  done &
fi

journalctl -f -u auditd -o cat --no-pager 2>/dev/null | while read -r line; do
  handle_line "$line"
done &

wait
WATCH_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-watch.sh"

# ── audit rules ──
cat > "$CHROOT/etc/audit/rules.d/eiciel.rules" <<'AUDIT_EOF'
# Root execve from an unset-auid session — always suspicious.
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid=4294967295 -k priv_esc_unset

# Root execve from a real user — evidence only, not an auto-trigger.
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -F auid!=4294967295 -k priv_esc_evidence

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

# Watcher tamper detection.
-w /etc/systemd/system/eiciel-watch.service -p wa -k watcher_tamper
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -F a1=stop -F a2=eiciel-watch -k watcher_tamper

-e 2
AUDIT_EOF

# ── fail2ban ──
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

# ── nftables default ──
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

# ── watcher unit ──
cat > "$CHROOT/etc/systemd/system/eiciel-watch.service" <<'UNIT_EOF'
[Unit]
Description=Eiciel audit watcher (triggers containment)
After=auditd.service
Requires=auditd.service
ConditionPathExists=/run/eiciel-licensed

[Service]
Type=simple
ExecStart=/usr/local/sbin/eiciel-watch.sh
RefuseManualStop=yes
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

# ── watchdog for watcher ──
cat > "$CHROOT/usr/local/sbin/eiciel-watchdog.sh" <<'WD_EOF'
#!/bin/bash
set -euo pipefail
if ! systemctl is-active --quiet eiciel-watch; then
  logger -t eiciel "watchdog: eiciel-watch down — restarting"
  systemctl start eiciel-watch || true
  /usr/local/sbin/eiciel-contain.sh >>/var/log/eiciel-contain.log 2>&1 &
fi
WD_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-watchdog.sh"

cat > "$CHROOT/etc/systemd/system/eiciel-watchdog.service" <<'WD_SVC'
[Unit]
Description=Eiciel watcher watchdog
After=eiciel-watch.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eiciel-watchdog.sh
WD_SVC

cat > "$CHROOT/etc/systemd/system/eiciel-watchdog.timer" <<'WD_TMR'
[Unit]
Description=Check eiciel-watch every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
WD_TMR

# ── heartbeat ──
cat > "$CHROOT/usr/local/sbin/eiciel-heartbeat.sh" <<'HB_EOF'
#!/bin/bash
set -euo pipefail
source /etc/eiciel/config.env
[ -n "${WEBHOOK_URL:-}" ] || exit 0
curl -fsS --max-time 5 -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"heartbeat\":\"$(hostname)\",\"time\":\"$(date -u +%FT%TZ)\"}" \
  >/dev/null 2>&1 || true
HB_EOF
chmod 755 "$CHROOT/usr/local/sbin/eiciel-heartbeat.sh"

cat > "$CHROOT/etc/systemd/system/eiciel-heartbeat.service" <<'HB_SVC'
[Unit]
Description=Eiciel heartbeat ping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eiciel-heartbeat.sh
HB_SVC

cat > "$CHROOT/etc/systemd/system/eiciel-heartbeat.timer" <<'HB_TMR'
[Unit]
Description=Eiciel heartbeat every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
HB_TMR

# ── Recovery runbook ──
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
ausearch -k priv_esc_unset --start today | less
ausearch -k ssh_keys       --start today | less
ausearch -k module_load    --start today | less
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

# ── MOTD ──
cat > "$CHROOT/etc/profile.d/eiciel-motd.sh" <<'MOTD_EOF'
#!/bin/sh
if [ -t 0 ]; then
  LIC_STATE="unknown"
  [ -f /run/eiciel-license-state ] && LIC_STATE="$(cat /run/eiciel-license-state)"
  cat <<BANNER

  ╔══════════════════════════════════════════════════════════╗
  ║  Eiciel Server — containment stack active                ║
  ║                                                          ║
  ║  License   : ${LIC_STATE}
  ║  Config    : /etc/eiciel/config.env                      ║
  ║  Evidence  : /var/lib/incidents/<timestamp>-<pid>/       ║
  ║  Recovery  : /root/RECOVERY.md                           ║
  ║  Dashboard : ssh -X admin@<host>                         ║
  ║              sudo -u eiciel /usr/local/bin/eiciel-dashboard
  ║  Manual    : sudo /usr/local/sbin/eiciel-contain.sh      ║
  ║  Lift      : sudo nft delete table inet eiciel_contain   ║
  ║  License   : sudo eiciel-license-install <json> <sig>    ║
  ║  Install   : sudo debian-installer-launcher              ║
  ╚══════════════════════════════════════════════════════════╝

BANNER
fi
MOTD_EOF
chmod 755 "$CHROOT/etc/profile.d/eiciel-motd.sh"

# ── authorized_keys ──
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

# ── Dashboard + daemon ──
if [ "$SHIP_DASHBOARD" = "1" ]; then
  install -d -m 755 "$CHROOT/opt/eiciel-dashboard"
  cp -a "$APP_DIST/." "$CHROOT/opt/eiciel-dashboard/"
  chmod -R 755 "$CHROOT/opt/eiciel-dashboard"

  install -d -m 755 "$CHROOT/usr/local/lib/eicield"
  install -m 755 "$DAEMON_DIST/eicield.py"          "$CHROOT/usr/local/lib/eicield/eicield.py"
  install -m 644 "$DAEMON_DIST/eicield.service"     "$CHROOT/etc/systemd/system/eicield.service"

  cat > "$CHROOT/usr/local/bin/eiciel-dashboard" <<'LAUNCH'
#!/bin/bash
exec sudo -u eiciel -H /opt/eiciel-dashboard/EicielDashboard "$@"
LAUNCH
  chmod 755 "$CHROOT/usr/local/bin/eiciel-dashboard"
fi

# ── Hook 030 — enable services ──
if [ "$LICENSE_GATE_MODE" = "hard" ]; then
  HARD_ENABLE="systemctl enable eiciel-license-hard-lock.service"
else
  HARD_ENABLE=":"
fi

cat > config/hooks/030-enable-services.hook.chroot <<EOF
#!/bin/bash
set -e
systemctl enable auditd
augenrules --load 2>/dev/null || true
systemctl enable fail2ban
systemctl enable nftables
systemctl enable ssh
systemctl enable eiciel-watch
systemctl enable eiciel-watchdog.timer
systemctl enable eiciel-heartbeat.timer
systemctl enable eicield.service
systemctl enable eiciel-license-gate.service
$HARD_ENABLE
install -d -m 2755 /var/log/journal
systemctl enable systemd-journald
EOF
chmod +x config/hooks/030-enable-services.hook.chroot

# ── Hook 040 — verify ──
cat > config/hooks/040-verify.hook.chroot <<'EOF'
#!/bin/bash
set -e
fail=0

FILES="/usr/local/sbin/eiciel-contain.sh
/usr/local/sbin/eiciel-watch.sh
/usr/local/sbin/eiciel-watchdog.sh
/usr/local/sbin/eiciel-heartbeat.sh
/etc/eiciel/config.env
/etc/audit/rules.d/eiciel.rules
/etc/fail2ban/jail.d/eiciel.local
/etc/nftables.conf
/etc/systemd/system/eiciel-watch.service
/etc/systemd/system/eicield.service
/usr/local/lib/eicield/eicield.py
/root/RECOVERY.md
/etc/profile.d/eiciel-motd.sh"

if [ -f /etc/eiciel/license.pub ]; then
  FILES="$FILES
/usr/local/sbin/eiciel-license-check
/usr/local/sbin/eiciel-license-gate
/usr/local/bin/eiciel-license-install
/etc/systemd/system/eiciel-license-gate.service"
fi

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -e "$f" ] || { echo "  ❌ missing: $f"; fail=1; }
done <<< "$FILES"

[ -x /usr/local/sbin/eiciel-contain.sh ] || { echo "  ❌ contain not executable"; fail=1; }
[ -x /usr/local/sbin/eiciel-watch.sh ]   || { echo "  ❌ watch not executable";   fail=1; }
[ "$(stat -c '%a' /etc/eiciel/config.env)" = "600" ] || { echo "  ❌ config.env mode wrong"; fail=1; }

if grep -rqE 'NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
  echo "  ❌ NOPASSWD:ALL present in sudoers"; fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "[040] All checks passed."
EOF
chmod +x config/hooks/040-verify.hook.chroot

# ── Hook 060 — cleanup ──
cat > config/hooks/060-cleanup.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true

if [ "${BUILD_MODE:-live}" = "live" ]; then
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
  find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
fi

chmod 644 /root/RECOVERY.md
chmod 755 /usr/local/sbin/eiciel-contain.sh
chmod 755 /usr/local/sbin/eiciel-watch.sh
chmod 600 /etc/eiciel/config.env
EOF
chmod +x config/hooks/060-cleanup.hook.chroot
chmod +x config/hooks/*.hook.chroot

# ── package list ──
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
openssl

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

if [ "$BUILD_MODE" = "install" ]; then
  cat >> config/package-lists/eiciel.list.chroot <<'EOF'
debian-installer-launcher
EOF
fi

# ── static chroot files ──
echo "$HOSTNAME_NEW" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_NEW
::1         localhost ip6-localhost ip6-loopback
EOF

# ── GRUB ──
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
BUILD_MODE="$BUILD_MODE" LICENSE_GATE_MODE="$LICENSE_GATE_MODE" lb chroot 2>&1 | tee chroot.log
lb binary 2>&1 | tee binary.log

ISO=$(ls -1 *.iso 2>/dev/null | head -1 || true)
[ -n "$ISO" ] || { echo "❌ No ISO produced."; exit 1; }
[ "$ISO" = "eiciel-server.iso" ] || { mv "$ISO" eiciel-server.iso; ISO="eiciel-server.iso"; }

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅  Done!  $ROOT/$ISO   ($(du -h "$ISO" | cut -f1))"
echo "      BUILD_MODE   = $BUILD_MODE"
echo "      Persistence  = $([ "$ENABLE_PERSISTENCE" = "1" ] && echo yes || echo no)"
echo "      Installer    = $([ "$BUILD_MODE" = "install" ] && echo yes || echo no)"
echo "      License gate = $LICENSE_GATE_MODE"
echo "═══════════════════════════════════════════════════════════════"
