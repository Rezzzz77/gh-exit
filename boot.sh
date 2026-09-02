#!/bin/bash
# راه‌انداز امن ناظر — الگوی pkill داخل فایل است، پس پوسته SSH خودش را نمی‌کشد
#
# مهم: اینجا cloudflared را نمی‌کشیم. اگر تونل فعلی سالم باشد ناظر تازه
# همان را تحویل می‌گیرد و کاربر هیچ قطعی نمی‌بیند. تصمیم دربارهٔ تونل
# فقط کار خود ناظر است.
set -u
PAT='s''up-run.sh'
for p in $(pgrep -f "$PAT" 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  kill -9 "$p" 2>/dev/null && echo "  ناظر قدیمی $p کشته شد"
done
sleep 1

# اسکریپت را از API می‌خوانیم نه raw، چون raw حدود پنج دقیقه کش دارد
# و ممکن است نسخه کهنه بدهد.
TOK=""
[ -s $HOME/.ghpat ] && TOK=$(cat $HOME/.ghpat)
OK=0
if [ -n "$TOK" ]; then
  curl -s -o $HOME/sup-new.sh --max-time 40 \
    -H "Authorization: Bearer $TOK" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/Rezzzz77/gh-exit/contents/supervise.sh"
  head -1 $HOME/sup-new.sh 2>/dev/null | grep -q '^#!/bin/bash' && OK=1
fi
if [ "$OK" != "1" ]; then
  echo "  خواندن از API نشد → raw"
  curl -sL -o $HOME/sup-new.sh \
    "https://raw.githubusercontent.com/Rezzzz77/gh-exit/main/supervise.sh"
fi

if bash -n $HOME/sup-new.sh 2>/dev/null; then
  mv $HOME/sup-new.sh $HOME/sup-run.sh
else
  echo "  !! اسکریپت دانلودی سالم نیست، نسخه قبلی نگه داشته شد"
  rm -f $HOME/sup-new.sh
fi

echo "  اسکریپت: $(wc -c < $HOME/sup-run.sh) بایت"
chmod +x $HOME/sup-run.sh
: > $HOME/sup.log
setsid nohup bash $HOME/sup-run.sh </dev/null >/dev/null 2>&1 &
echo "  ناظر راه افتاد"
