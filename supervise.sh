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

log(){ echo "$(date -u +%H:%M:%S) $*" >> $LOG; }

# ── کانفیگ بک‌اند: هر بار نوشته می‌شود تا فهرست کاربران به‌روز باشد ──
write_conf(){
  mkdir -p $D
  cat > $D/be.json <<'JSON'
{
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [{
    "port": 8080,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "50e427ac-5eb5-481b-8717-f4778c4ddf76", "email": "reza"},
        {"id": "4c6830b6-a129-4a8b-bba6-71692d7c7129", "email": "banoo"}
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
}

publish(){
  local h="$1"
  [ -s "$TOKF" ] || { log "توکن نیست، انتشار رد شد"; return 1; }
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
  log "انتشار $h → HTTP $code"
  [ "$code" = "200" ] || [ "$code" = "201" ]
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
  curl -s -o /dev/null --max-time 10 https://www.google.com/generate_204 2>/dev/null
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

# تونل‌های به‌جامانده از اجرای قبلی را پاک کن، بعد یکی تازه بساز
pkill -x cloudflared 2>/dev/null
rm -f $CFPID
sleep 2
until rotate; do log "تلاش مجدد برای بالا آوردن تونل"; sleep 20; done

while :; do
  start_xray
  keepalive

  CFP=$(cat $CFPID 2>/dev/null)
  if [ -z "$CFP" ] || ! kill -0 "$CFP" 2>/dev/null; then
    log "فرایند تونل مرده → تونل تازه"
    rotate || sleep 20
    sleep 45
    continue
  fi

  TH=$(cat $HOSTFILE 2>/dev/null)
  if [ -n "$TH" ]; then
    C=$(ws101 "$TH")
    if [ "$C" != "101" ]; then
      FAILS=$((FAILS+1))
      log "سلامت تونل خراب (کد=$C) شماره $FAILS"
      if [ "$FAILS" -ge "$MAXFAIL" ]; then
        log "$MAXFAIL خرابی پیاپی → جایگزینی نرم تونل"
        rotate || { log "جایگزینی نشد"; sleep 20; }
      fi
    else
      FAILS=0
      reclaim "$TH"
    fi
  fi
  sleep 45
done
