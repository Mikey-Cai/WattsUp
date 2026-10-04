#!/bin/sh
# WattsUp 功耗采样助手(以 root 运行,由 /Library/LaunchDaemons/io.github.mikey-cai.wattsup.power.plist 拉起)。
# 只在 WattsUp 最近 15 秒内碰过 /var/tmp/wattsup.want 时才跑 powermetrics(平时只睡觉,不耗电);
# 结果原子写到 root 自己的目录 /var/tmp/wattsup/power.plist,普通用户可读不可写。
OUT=/var/tmp/wattsup
WANT=/var/tmp/wattsup.want
mkdir -p "$OUT" && chown root:wheel "$OUT" && chmod 755 "$OUT"
while true; do
  if [ -f "$WANT" ] && [ $(( $(date +%s) - $(stat -f %m "$WANT") )) -lt 15 ]; then
    if /usr/bin/powermetrics -n 1 -i 1000 --samplers cpu_power,gpu_power,ane_power -f plist > "$OUT/power.tmp" 2>"$OUT/error.log"; then
      chmod 644 "$OUT/power.tmp" && mv -f "$OUT/power.tmp" "$OUT/power.plist"
    else
      sleep 5
    fi
  else
    sleep 3
  fi
done
