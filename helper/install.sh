#!/bin/zsh
# 可选:安装 WattsUp 的 powermetrics 采样助手(需要 sudo),在项目目录运行:
#   sudo zsh helper/install.sh
# 卸载:sudo zsh helper/install.sh --uninstall
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行"; exit 1; }
HERE="${0:A:h}"
LABEL=io.github.mikey-cai.wattsup.power
DIR="/Library/Application Support/WattsUp"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

launchctl bootout "system/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$PLIST" "$DIR/power-sampler.sh"; rmdir "$DIR" 2>/dev/null || true
  echo "已卸载"; exit 0
fi
mkdir -p "$DIR"
install -o root -g wheel -m 755 "$HERE/power-sampler.sh" "$DIR/power-sampler.sh"
install -o root -g wheel -m 644 "$HERE/$LABEL.plist" "$PLIST"
launchctl bootstrap system "$PLIST"
echo "已安装并启动 $LABEL"
# 自测:模拟 WattsUp 要数据,等一次采样
touch /var/tmp/wattsup.want; chmod 666 /var/tmp/wattsup.want
sleep 6
if [[ -s /var/tmp/wattsup/power.plist ]]; then
  echo "采样正常:"; /usr/libexec/PlistBuddy -c "Print :processor" /var/tmp/wattsup/power.plist 2>/dev/null | grep -i -E "power|energy" | head -8
else
  echo "还没有采样结果,看 /var/tmp/wattsup/error.log"; cat /var/tmp/wattsup/error.log 2>/dev/null | head -5
fi
