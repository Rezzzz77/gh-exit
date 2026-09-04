#!/bin/bash
# ناظر روی کداسپیس
#   ۱) xray بک‌اند روی 8080 را زنده نگه می‌دارد
#   ۲) تونل کلادفلر را زنده نگه می‌دارد
#   ۳) هر بار میزبان تونل عوض شد آن را در ریپو gh-exit منتشر می‌کند
#      تا ورکر ثابت gh.arshadirad7475.workers.dev مقصد درست را پیدا کند
#
# نکته اصلی این نسخه: «جایگزینی نرم تونل».
# قبلاً وقتی تونل ری‌استارت می‌شد، میزبان قدیمی همان لحظه می‌مرد ولی
# ورکر تا حدود پنج دقیقه مقدار کهنهٔ host.txt را از CDN می‌خواند و
# ترافیک را به میزبان مرده می‌فرستاد ⇒ کاربر «قطع شد» می‌دید.
# حالا تونل جدید اول بالا می‌آید و منتشر می‌شود و تونل قدیمی هفت دقیقه
# دیگر زنده می‌ماند تا کش تمام شود. بنابراین قطعی دیده نمی‌شود.
set -u
D=$HOME/xb
LOG=$HOME/sup.log
HOSTFILE=$HOME/tunnel-host.txt
CFPID=$HOME/cf.pid
REPO=Rezzzz77/gh-exit
TOKF=$HOME/.ghpat
OVERLAP=420          # چند ثانیه تونل قدیمی زنده بماند (کش CDN حدود ۵ دقیقه)
MAXFAIL=6            # شش خرابی پیاپی (~۴.۵ دقیقه) تا جایگزینی تونل
PUBHOST=gh.arshadirad7475.workers.dev
PUBEVERY=4           # آزمون عمومی هر چند دور (۴ × ۴۵ث ≈ ۳ دقیقه) تا 429 نخوریم

# ── ورکر نسل دو ─────────────────────────────────────────────────────────
# میزبان تونل را همان لحظه به ورکر می‌دهیم (KV، بدون کش). host.txt در ریپو
# فقط پشتیبان می‌ماند. کلید انتشار در $HOME/.gh2key است.
W2=gh2.arshadirad7475.workers.dev
K2F=$HOME/.gh2key

# ── خودخاموش‌کن برای صرفه‌جویی سهمیه ────────────────────────────────────
# اگر IDLE_STOP=1 باشد و به اندازه IDLE_MIN دقیقه هیچ ترافیک واقعی نیامده
# باشد، کداسپیس خودش را خاموش می‌کند. کاربر قطع نمی‌شود چون ورکر نسل دو
# خودش لایه دوم را سرو می‌کند.
IDLE_STOP=${IDLE_STOP:-1}
IDLE_MIN=${IDLE_MIN:-25}
ACCLOG=$D/access.log

# ── هاپ دوم WARP ────────────────────────────────────────────────────────
# claude.ai روی آی‌پی دیتاسنتر آزور چالش کلادفلر می‌خورد، پس فقط دامنه‌های
# Claude از یک تونل وایرگارد WARP بیرون می‌روند. کلید از سکرت کداسپیس
# ($WARP_JSON) یا فایل محلی می‌آید؛ اگر نبود، کانفیگ بدون WARP ساخته می‌شود.
WARPF=$HOME/.warp.json
if [ -n "${WARP_JSON:-}" ] && [ ! -s "$WARPF" ]; then
  printf '%s' "$WARP_JSON" > "$WARPF"
  chmod 600 "$WARPF"
fi

log(){ echo "$(date -u +%H:%M:%S) $*" >> $LOG; }

# فهرست کلاینت‌ها هرگز داخل مخزن نیست. از سکرت کداسپیس یا فایل محلی می‌آید.
#   ترتیب:  $VLESS_UUIDS  →  ~/.vlessids
#   قالب:   reza:UUID,banoo:UUID   یا فقط  UUID,UUID
load_clients(){
  IDS="${VLESS_UUIDS:-}"
  if [ -z "$IDS" ] && [ -s "$HOME/.vlessids" ]; then IDS=$(cat "$HOME/.vlessids"); fi
  CLIENTS=""
  N=0
  OLDIFS=$IFS
  IFS=',
'
  for it in $IDS; do
    it=$(printf '%s' "$it" | tr -d ' \t\r')
    [ -z "$it" ] && continue
    case "$it" in
      *:*) nm=${it%%:*}; id=${it##*:} ;;
      *)   nm="";        id=$it ;;
    esac
    ok=1
    [ ${#id} -eq 36 ] || ok=0
    case "$id" in *[!0-9a-fA-F-]*) ok=0 ;; esac
    if [ "$ok" != 1 ]; then log "!! یک شناسه نامعتبر رد شد"; continue; fi
    N=$((N+1))
    [ -z "$nm" ] && nm="u$N"
    if [ -n "$CLIENTS" ]; then CLIENTS="$CLIENTS,
"; fi
    CLIENTS="$CLIENTS        {\"id\": \"$id\", \"email\": \"$nm\"}"
  done
  IFS=$OLDIFS
  if [ "$N" -eq 0 ]; then
    log "!! فهرست کلاینت خالی است — نه VLESS_UUIDS و نه ~/.vlessids. xray بالا نمی‌آید."
    return 1
  fi
  log "فهرست کلاینت: $N کاربر"
  return 0
}

# کانفیگ بک‌اند: هر بار نوشته می‌شود تا فهرست کاربران به‌روز باشد
# اگر محتوا عوض شد، xray باید ری‌استارت شود وگرنه کاربر جدید را نمی‌شناسد
write_conf(){
  load_clients || return 1
  mkdir -p $D
  cat > $D/be.new <<JSON
{
  "log": {"loglevel": "warning", "access": "$ACCLOG"},
  "inbounds": [{
    "port": 8080,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [
$CLIENTS
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": {"path": "/tun"}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct",
     "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "port": "25,465,587", "outboundTag": "block"}
    ]
  }
}
JSON
  # دامنه‌های Claude → هاپ WARP (اگر اعتبارنامه موجود باشد)
  if [ -s "$WARPF" ]; then
    python3 - "$D/be.new" "$WARPF" <<'PYW' >>$LOG 2>&1
import json,sys
cfg,wf=sys.argv[1],sys.argv[2]
try:
    w=json.load(open(wf)); c=json.load(open(cfg))
    if "warp" not in [o.get("tag") for o in c["outbounds"]]:
        c["outbounds"].append({"protocol":"wireguard","tag":"warp","settings":{
            "secretKey":w["priv"],
            "address":[w["v4"]+"/32",w["v6"]+"/128"],
            "peers":[{"publicKey":w["peer_pub"],"endpoint":w["endpoint"],
                      "allowedIPs":["0.0.0.0/0","::/0"]}],
            "reserved":w["reserved"],"mtu":1280,"domainStrategy":"ForceIPv4"}})
    rules=c["routing"]["rules"]
    if not any(r.get("outboundTag")=="warp" for r in rules):
        rules.insert(0,{"type":"field","outboundTag":"warp","domain":[
            "domain:claude.ai","domain:anthropic.com",
            "domain:claudeusercontent.com","domain:claude.com"]})
    json.dump(c,open(cfg,"w"),indent=1)
except Exception as e:
    print("warp-inject رد شد: %s"%e)
PYW
  fi
  if [ -f $D/be.json ] && cmp -s $D/be.new $D/be.json; then
    rm -f $D/be.new
    return 0
  fi
  mv $D/be.new $D/be.json
  log "کانفیگ بک‌اند عوض شد → ری‌استارت xray"
  pkill -f 'xray run -c .*be.json' 2>/dev/null
  sleep 2
}

# انتشار فوری روی ورکر نسل دو (KV، بدون کش CDN)
pub_worker(){
  local h="$1" k code
  [ -s "$K2F" ] || return 1
  k=$(tr -d '\n' < $K2F)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://$W2/pub?k=$k&h=$h" 2>/dev/null)
  log "انتشار روی ورکر $h → HTTP $code"
  # لایه ۱ زنده است → فلگ خاموشی ورکر را پاک کن (اگر خودخاموشی قبلاً گذاشته)
  if [ "$code" = "200" ]; then
    curl -s -o /dev/null --max-time 20 "https://$W2/tier1?k=$k&v=0" 2>/dev/null
    return 0
  fi
  return 1
}

publish(){
  local h="$1"
  # اول ورکر: فوری اثر می‌کند. بعد ریپو: پشتیبان و پایدار.
  pub_worker "$h"
  [ -s "$TOKF" ] || { log "توکن نیست، انتشار در ریپو رد شد"; return 1; }
  local tok sha b64 body code
  tok=$(cat $TOKF)
  b64=$(printf '%s\n' "$h" | base64 -w0)
  sha=$(curl -s -H "Authorization: Bearer $tok" \
        "https://api.github.com/repos/$REPO/contents/host.txt" \
        | grep -oP '"sha":\s*"\K[0-9a-f]{40}' | head -1)
  if [ -n "$sha" ]; then
    body="{\"message\":\"host $h\",\"content\":\"$b64\",\"sha\":\"$sha\"}"
  else
    body="{\"message\":\"host $h\",\"content\":\"$b64\"}"
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "https://api.github.com/repos/$REPO/contents/host.txt")
  log "انتشار در ریپو $h → HTTP $code"
  [ "$code" = "200" ] || [ "$code" = "201" ]
}

# ── سنجش بیکاری و خودخاموشی ────────────────────────────────────────────
# لاگ دسترسی xray فقط با ترافیک واقعی VLESS رشد می‌کند. آزمون سلامت
# (دست‌دادن وب‌سوکت بدون داده) هیچ خطی نمی‌نویسد، پس معیار تمیزی است.
LAST_ACT=$(date +%s)
LAST_SZ=0
self_stop(){
  local tok cs code
  [ -s "$TOKF" ] || { log "توکن نیست، خودخاموشی ممکن نشد"; return 1; }
  tok=$(cat $TOKF)
  cs=${CODESPACE_NAME:-}
  [ -n "$cs" ] || { log "CODESPACE_NAME خالی است"; return 1; }
  log "بیکاری $IDLE_MIN دقیقه → خاموش کردن کداسپیس برای حفظ سهمیه"
  # به ورکر خبر بده لایه ۱ را کنار بگذارد (سریع‌تر لایه ۲ را سرو می‌کند)
  if [ -s "$K2F" ]; then
    k2=$(tr -d '\n' < $K2F)
    curl -s -o /dev/null --max-time 15 "https://$W2/tier1?k=$k2&v=1" 2>/dev/null
  fi
  # به گوشی خبر بده که لایه دو را سرو کند
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user/codespaces/$cs/stop" 2>/dev/null)
  log "درخواست stop → HTTP $code"
}

check_idle(){
  [ "$IDLE_STOP" = "1" ] || return 0
  local sz now
  sz=$(stat -c %s "$ACCLOG" 2>/dev/null || echo 0)
  now=$(date +%s)
  # لاگ را بیش از ۲۰ مگابایت بزرگ نکن
  if [ "${sz:-0}" -gt 20000000 ]; then
    : > "$ACCLOG"
    sz=0
  fi
  if [ "$sz" != "$LAST_SZ" ]; then
    LAST_SZ=$sz
    LAST_ACT=$now
    return 0
  fi
  if [ $(( (now - LAST_ACT) / 60 )) -ge "$IDLE_MIN" ]; then
    self_stop
    LAST_ACT=$now
  fi
}

start_xray(){
  pgrep -f 'xray run -c .*be.json' >/dev/null && return 0
  log "راه‌اندازی xray"
  setsid nohup $D/xray run -c $D/be.json </dev/null >>$D/be.log 2>&1 &
  sleep 3
}

ws101(){   # آزمون دست‌دادن وب‌سوکت روی یک میزبان
  curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 15 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Sec-WebSocket-Version: 13' "https://$1/tun" 2>/dev/null
}

# آزمون محلی: مستقیم روی خود xray، بدون رد شدن از کلادفلر.
# این سنجه هیچ‌وقت محدود (429) نمی‌شود و سلامت واقعی بک‌اند را می‌گوید.
ws101_local(){
  curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 8 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Sec-WebSocket-Version: 13' \
    -H "Host: $PUBHOST" "http://127.0.0.1:8080/tun" 2>/dev/null
}

# یک تونل تازه می‌سازد و «pid host» را چاپ می‌کند.
# با http2 کار می‌کند نه QUIC؛ QUIC روی آژور مرتب timeout می‌داد.
spawn_tunnel(){
  local tag=$1 lf=$HOME/cf-$1.log pf=$HOME/cf-$1.pid
  : > $lf; rm -f $pf
  setsid nohup bash -c "echo \$\$ > $pf; exec $HOME/cloudflared tunnel \
      --url http://127.0.0.1:8080 --no-autoupdate --edge-ip-version 4 \
      --protocol http2 >> $lf 2>&1" </dev/null >/dev/null 2>&1 &
  local h="" i
  for i in $(seq 1 30); do
    h=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' $lf 2>/dev/null | head -1)
    [ -n "$h" ] && break
    sleep 2
  done
  local pid; pid=$(cat $pf 2>/dev/null)
  [ -z "$h" ] && { log "!! میزبان تونل پیدا نشد"; [ -n "$pid" ] && kill $pid 2>/dev/null; echo ""; return 1; }
  h=${h#https://}
  local c=""
  for i in $(seq 1 20); do
    c=$(ws101 "$h")
    [ "$c" = "101" ] && break
    sleep 3
  done
  if [ "$c" != "101" ]; then
    log "!! تونل $h سرویس نداد (کد=$c)"
    [ -n "$pid" ] && kill $pid 2>/dev/null
    echo ""; return 1
  fi
  echo "$pid $h"
}

# جایگزینی نرم: تونل جدید بالا می‌آید، منتشر می‌شود، بعد قدیمی می‌رود
rotate(){
  local old; old=$(cat $CFPID 2>/dev/null)
  local tag; tag=$(date +%s)
  local out; out=$(spawn_tunnel "$tag") || return 1
  [ -n "$out" ] || return 1
  local npid nhost
  npid=${out%% *}; nhost=${out##* }
  publish "$nhost" && echo "$nhost" > $HOME/tunnel-host.prev
  echo "$npid" > $CFPID
  echo "$nhost" > $HOSTFILE
  log "تونل جدید: $nhost (pid $npid)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    log "تونل قدیمی pid $old تا $OVERLAP ثانیه دیگر زنده می‌ماند"
    ( sleep $OVERLAP; kill "$old" 2>/dev/null; \
      log "تونل قدیمی pid $old خاموش شد" ) </dev/null >/dev/null 2>&1 &
  fi
  # تونل‌های یتیم را جمع کن (اگر بیش از دو تا شد)
  local n; n=$(pgrep -c -x cloudflared 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 2 ] && log "هشدار: $n تونل همزمان"
  FAILS=0
  return 0
}

keepalive(){
  touch $HOME/.keepalive
}

# اگر گره پشتیبان (Actions) میزبان را برداشته باشد، کداسپیس پس می‌گیرد.
# raw.githubusercontent حدود پنج دقیقه کش دارد و برای داوری بی‌اعتبار است؛ از API می‌خوانیم.
LAST_RECLAIM=0
reclaim(){
  local mine="$1"
  [ -n "$mine" ] || return 0
  [ -s "$TOKF" ] || return 0
  local now; now=$(date +%s)
  [ $(( now - LAST_RECLAIM )) -lt 300 ] && return 0
  local tok live
  tok=$(cat $TOKF)
  live=$(curl -s --max-time 20 \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/$REPO/contents/host.txt" 2>/dev/null | tr -d '\r\n')
  case "$live" in
    *trycloudflare.com) : ;;
    *) return 0 ;;
  esac
  if [ "$live" != "$mine" ]; then
    log "host.txt مال $live بود → کداسپیس پس می‌گیرد"
    LAST_RECLAIM=$now
    publish "$mine" && echo "$mine" > $HOME/tunnel-host.prev
  fi
}

log "=== ناظر شروع شد ==="
FAILS=0
write_conf
start_xray

# تحویل گرفتن تونل سالم قبلی: اگر میزبان قبلی هنوز ۱۰۱ می‌دهد و فرایندش زنده است
# دست به آن نمی‌زنیم. این‌طور ری‌استارت ناظر برای کاربر قطعی نمی‌سازد.
adopt(){
  local ph pp c
  ph=$(cat $HOSTFILE 2>/dev/null)
  [ -n "$ph" ] || return 1
  pp=$(cat $CFPID 2>/dev/null)
  if [ -z "$pp" ] || ! kill -0 "$pp" 2>/dev/null; then
    # فرایند را از فهرست پیدا کن (تک تونل)
    pp=$(pgrep -x cloudflared | head -1)
  fi
  [ -n "$pp" ] || return 1
  c=$(ws101 "$ph")
  [ "$c" = "101" ] || return 1
  echo "$pp" > $CFPID
  log "تونل سالم قبلی تحویل گرفته شد: $ph (pid $pp)"
  reclaim "$ph"
  return 0
}

if ! adopt; then
  pkill -x cloudflared 2>/dev/null
  rm -f $CFPID
  sleep 2
  until rotate; do log "تلاش مجدد برای بالا آوردن تونل"; sleep 20; done
fi

ROUND=0
while :; do
  ROUND=$((ROUND+1))
  write_conf
  start_xray
  keepalive
  check_idle

  CFP=$(cat $CFPID 2>/dev/null)
  if [ -z "$CFP" ] || ! kill -0 "$CFP" 2>/dev/null; then
    log "فرایند تونل مرده → تونل تازه"
    rotate || sleep 20
    sleep 45
    continue
  fi

  # مرحله یک: سلامت محلی بک‌اند. اگر این خراب باشد ایراد واقعی از xray است.
  L=$(ws101_local)
  if [ "$L" != "101" ]; then
    log "xray محلی جواب نداد (کد=$L) → ری‌استارت xray"
    pkill -f 'xray run -c .*be.json' 2>/dev/null
    sleep 3
    start_xray
    sleep 45
    continue
  fi

  # مرحله دو: مسیر عمومی — فقط هر چند دور، وگرنه کلادفلر 429 می‌دهد.
  TH=$(cat $HOSTFILE 2>/dev/null)
  if [ -n "$TH" ] && [ $((ROUND % PUBEVERY)) -eq 0 ]; then
    C=$(ws101 "$TH")
    case "$C" in
      101)
        FAILS=0
        reclaim "$TH"
        ;;
      429|403|503)
        # محدودیت نرخ یا سپر کلادفلر در برابر خود ما — تونل سالم است.
        # بک‌اند محلی بالا است، پس هیچ کاری نمی‌کنیم.
        log "آزمون عمومی کد=$C (محدودیت نرخ) — نادیده گرفته شد"
        FAILS=0
        ;;
      *)
        FAILS=$((FAILS+1))
        log "سلامت تونل خراب (کد=$C) شماره $FAILS"
        if [ "$FAILS" -ge "$MAXFAIL" ]; then
          log "$MAXFAIL خرابی پیاپی → جایگزینی نرم تونل"
          rotate || { log "جایگزینی نشد"; sleep 20; }
        fi
        ;;
    esac
  fi
  sleep 45
done
