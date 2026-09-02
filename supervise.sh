#!/bin/bash
# ناظر روی کداسپیس:
#   1) xray بک‌اند روی 8080 را زنده نگه می‌دارد
#   2) تونل کلادفلر را زنده نگه می‌دارد
#   3) هر بار میزبان تونل عوض شد، آن را در ریپو gh-exit منتشر می‌کند
#      تا ورکر ثابت gh.arshadirad7475.workers.dev همیشه مقصد درست را پیدا کند
set -u
D=$HOME/xb
LOG=$HOME/sup.log
HOSTFILE=$HOME/tunnel-host.txt
REPO=Rezzzz77/gh-exit
TOKF=$HOME/.ghpat

log(){ echo "$(date -u +%H:%M:%S) $*" >> $LOG; }

publish(){
  local h="$1"
  [ -s "$TOKF" ] || { log "توکن نیست، انتشار رد شد"; return 1; }
  local tok sha b64
  tok=$(cat $TOKF)
  b64=$(printf '%s\n' "$h" | base64 -w0)
  sha=$(curl -s -H "Authorization: Bearer $tok" \
        "https://api.github.com/repos/$REPO/contents/host.txt" \
        | grep -oP '"sha":\s*"\K[0-9a-f]{40}' | head -1)
  local body
  if [ -n "$sha" ]; then
    body="{\"message\":\"host $h\",\"content\":\"$b64\",\"sha\":\"$sha\"}"
  else
    body="{\"message\":\"host $h\",\"content\":\"$b64\"}"
  fi
  local code
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

start_tunnel(){
  pgrep -x cloudflared >/dev/null && return 0
  log "راه‌اندازی تونل کلادفلر"
  : > $HOME/cf.log
  setsid nohup $HOME/cloudflared tunnel --url http://127.0.0.1:8080 \
      --no-autoupdate --edge-ip-version 4 </dev/null >>$HOME/cf.log 2>&1 &
  local h=""
  for i in $(seq 1 25); do
    h=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' $HOME/cf.log 2>/dev/null | head -1)
    [ -n "$h" ] && break
    sleep 2
  done
  if [ -z "$h" ]; then log "!! میزبان تونل پیدا نشد"; return 1; fi
  h=${h#https://}
  # صبر تا تونل واقعاً سرویس بدهد
  for i in $(seq 1 15); do
    C=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 12 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H 'Sec-WebSocket-Version: 13' "https://$h/tun" 2>/dev/null)
    [ "$C" = "101" ] && break
    sleep 3
  done
  local old=""
  [ -f $HOME/tunnel-host.prev ] && old=$(cat $HOME/tunnel-host.prev)
  echo "$h" > $HOSTFILE
  if [ "$h" != "$old" ]; then
    publish "$h" && echo "$h" > $HOME/tunnel-host.prev
  fi
  log "میزبان تونل: $h (سلامت=$C)"
  FAILS=0
}

keepalive(){
  # جلوگیری از توقف کداسپیس در حالت بی‌کاری
  curl -s -o /dev/null --max-time 10 https://www.google.com/generate_204 2>/dev/null
  touch $HOME/.keepalive
}

# اگر گره پشتیبان (Actions) میزبان را دزدیده باشد، کداسپیس آن را پس می‌گیرد
# چون پینگ آمستردام برای ایران بهتر از رانر آمریکا است.
reclaim(){
  local mine="$1"
  [ -n "$mine" ] || return 0
  local live
  live=$(curl -s --max-time 20 \
        "https://raw.githubusercontent.com/$REPO/main/host.txt" 2>/dev/null | tr -d '\r\n')
  [ -n "$live" ] || return 0
  if [ "$live" != "$mine" ]; then
    log "host.txt مال $live بود → کداسپیس پس می‌گیرد"
    publish "$mine" && echo "$mine" > $HOME/tunnel-host.prev
  fi
}

log "=== ناظر شروع شد ==="
FAILS=0
start_xray
start_tunnel

while :; do
  start_xray
  start_tunnel
  keepalive
  # سلامت سرتاسری: اگر تونل جواب نداد، cloudflared را دور بینداز
  TH=$(cat $HOSTFILE 2>/dev/null)
  if [ -n "$TH" ]; then
    C=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 15 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H 'Sec-WebSocket-Version: 13' "https://$TH/tun" 2>/dev/null)
    if [ "$C" != "101" ]; then
      FAILS=$((FAILS+1))
      log "سلامت تونل خراب (کد=$C) شماره $FAILS"
      if [ "$FAILS" -ge 3 ]; then
        log "سه خرابی پیاپی → ری‌استارت تونل"
        pkill -x cloudflared 2>/dev/null
        FAILS=0
        sleep 3
      fi
    else
      FAILS=0
      reclaim "$TH"
    fi
  fi
  sleep 45
done
