#!/usr/bin/env bash
# 重启 Hermes gateway 以加载 ztk 集成
set -euo pipefail
PID_FILE=~/.hermes/gateway.pid

echo "=== 当前 gateway ==="
ps aux | grep 'hermes_cli.main gateway' | grep -v grep || echo "(none)"

echo ""
echo "=== 优雅停止 ==="
if [[ -f "$PID_FILE" ]]; then
    pid=$(python3 -c "import json; print(json.load(open('$PID_FILE'))['pid'])")
    echo "Killing PID $pid..."
    kill "$pid" || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "OK exited"
            break
        fi
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
fi

echo ""
echo "=== 启动新 gateway ==="
nohup /vol2/1000/Hermes/.venv/bin/python -m hermes_cli.main gateway run --replace \
    > ~/.hermes/logs/gateway.log 2>&1 &
echo "New PID: $!"
echo $! > /tmp/hermes-gateway.pid

sleep 5
echo ""
echo "=== 验证 ==="
ps aux | grep 'hermes_cli.main gateway' | grep -v grep | head -2 || echo "FAILED"
tail -10 ~/.hermes/logs/gateway.log
