// ============================================================
// k6/latency.js —— 延迟 / 吞吐
//
// 用法：
//   k6 run -e RPS=1000 -e DUR=30s -e OUT=out/latency.json k6/latency.js
//
// 关键点：用 constant-arrival-rate，不用 VU 循环。
// VU 循环下 RPS 会随响应时间漂移，两组数据就没法比了。
// ============================================================
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const allowed = new Counter('rl_allowed');
const limited = new Counter('rl_limited');

const NODES = (__ENV.NODES ||
  'http://localhost:8030,http://localhost:8010,http://localhost:8020').split(',');

const RPS = Number(__ENV.RPS || 200);
const DUR = __ENV.DUR || '30s';

export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: DUR,
      preAllocatedVUs: Math.max(50, Math.ceil(RPS / 5)),
      maxVUs: Math.max(200, RPS * 2),
    },
  },
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const node = NODES[__ITER % NODES.length];
  const res = http.get(`${node}/echo`, { tags: { node: node } });

  if (res.status === 200) {
    allowed.add(1);
  } else if (res.status === 429) {
    limited.add(1);
  }
}

export function handleSummary(data) {
  const out = __ENV.OUT || 'latency-summary.json';
  const d = data.metrics.http_req_duration.values;
  console.log(
    `rps=${(data.metrics.http_reqs.values.rate).toFixed(0)} ` +
    `p50=${d.med.toFixed(2)}ms p95=${d['p(95)'].toFixed(2)}ms p99=${d['p(99)'].toFixed(2)}ms`
  );
  return { [out]: JSON.stringify(data, null, 2) };
}
