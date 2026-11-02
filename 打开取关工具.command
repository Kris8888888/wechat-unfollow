#!/bin/bash
# 双击打开「公众号取关」。这个终端窗口别关，关了工具就停了。
cd "$(dirname "$0")" || exit 1
clear
if [ ! -x bin/wxunf ]; then
  echo "缺少 bin/wxunf，请先运行 build.sh"; read -r -p "按回车退出"; exit 1
fi
exec /usr/bin/python3 -u server.py
