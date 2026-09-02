#!/bin/bash
# راه‌انداز امن ناظر — الگوی pkill داخل فایل است، پس پوسته SSH خودش را نمی‌کشد
set -u
PAT='s''up-run.sh'
for p in $(pgrep -f "$PAT" 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  kill -9 "$p" 2>/dev/null && echo "  ناظر قدیمی $p کشته شد"
done
pkill -x cloudflared 2>/dev/null && echo "  cloudflared کشته شد"
sleep 2

curl -sL -o $HOME/sup-run.sh \
  "https://raw.githubusercontent.com/Rezzzz77/gh-exit/main/supervise.sh"
echo "  اسکریپت: $(wc -c < $HOME/sup-run.sh) بایت | FAILS=$(grep -c FAILS $HOME/sup-run.sh)"
chmod +x $HOME/sup-run.sh
: > $HOME/sup.log
setsid nohup bash $HOME/sup-run.sh </dev/null >/dev/null 2>&1 &
echo "  ناظر راه افتاد"
