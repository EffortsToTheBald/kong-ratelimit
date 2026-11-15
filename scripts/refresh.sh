docker compose restart kong1 kong2 kong3
sleep 3 && curl -s -o /dev/null -w 'kong1 ready: %{http_code}\n' localhost:8031/status   # 期望 200
docker compose exec redis redis-cli FLUSHDB