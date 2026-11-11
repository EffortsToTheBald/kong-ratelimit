
// ============================================================
// k6/quota.js —— 配额正确性 + 节点请求分布统计
//
// 用法：
//   k6 run -e NODES=http://localhost:8030,http://localhost:8010,http://localhost:8020 \
//          -e VUS=3 -e ITER=450 -e OUT=out/quota.json k6/quota.js
//
// 目的：
//   1. 三个节点轮流打，统计总放行数
//   2. 统计每个节点实际收到的请求数
//   3. 统计每个节点的放行数、限流数和异常数
// ============================================================

import http from 'k6/http';
import { Counter } from 'k6/metrics';

const allowed = new Counter('rl_allowed');
const limited = new Counter('rl_limited');
const other = new Counter('rl_other');

// 每个节点的请求统计
const nodeRequests = [
  new Counter('requests_kong1'),
  new Counter('requests_kong2'),
  new Counter('requests_kong3'),
];

const nodeAllowed = [
  new Counter('allowed_kong1'),
  new Counter('allowed_kong2'),
  new Counter('allowed_kong3'),
];

const nodeLimited = [
  new Counter('limited_kong1'),
  new Counter('limited_kong2'),
  new Counter('limited_kong3'),
];

const nodeOther = [
  new Counter('other_kong1'),
  new Counter('other_kong2'),
  new Counter('other_kong3'),
];

const NODES = (__ENV.NODES ||
  'http://localhost:8030,http://localhost:8010,http://localhost:8020'
).split(',');

if (NODES.length !== 3) {
  throw new Error(`当前脚本要求配置3个节点，实际配置了${NODES.length}个`);
}

const VUS = Number(__ENV.VUS || 30);
const TOTAL_ITER = Number(__ENV.ITER || 450);

if (TOTAL_ITER % VUS !== 0) {
  throw new Error(
    `ITER 必须能够被 VUS 整除：ITER=${TOTAL_ITER}, VUS=${VUS}`
  );
}

export const options = {
  scenarios: {
    quota: {
      executor: 'per-vu-iterations',
      vus: VUS,
      iterations: TOTAL_ITER / VUS,
      maxDuration: '5m',
    },
  },

  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  // VU固定绑定节点
  const index = (__VU - 1) % NODES.length;
  const node = NODES[index];

  // 统计实际发往该节点的请求
  nodeRequests[index].add(1);

  const res = http.get(`${node}/echo`, {
    tags: { node: node },
    redirects: 0,
  });

  if (res.status === 200) {
    allowed.add(1);
    nodeAllowed[index].add(1);
  } else if (res.status === 429) {
    limited.add(1);
    nodeLimited[index].add(1);
  } else {
    other.add(1);
    nodeOther[index].add(1);
  }
}

export function handleSummary(data) {
  const out = __ENV.OUT || 'quota-summary.json';

  function count(name) {
    return data.metrics[name]?.values?.count || 0;
  }

  console.log('\n========== 全局统计 ==========');
  console.log(`allowed=${count('rl_allowed')}`);
  console.log(`limited=${count('rl_limited')}`);
  console.log(`other=${count('rl_other')}`);

  console.log('\n========== 节点请求分布 ==========');

  for (let i = 0; i < 3; i++) {
    const name = `kong${i + 1}`;

    console.log(
      `${name}: ` +
      `requests=${count(`requests_${name}`)} ` +
      `allowed=${count(`allowed_${name}`)} ` +
      `limited=${count(`limited_${name}`)} ` +
      `other=${count(`other_${name}`)}`
    );
  }

  return {
    [out]: JSON.stringify(data, null, 2),
  };
}
