
// ============================================================
// k6/quota.js —— quota correctness + per-node request distribution stats
//
// Usage:
//   k6 run -e NODES=http://localhost:8030,http://localhost:8010,http://localhost:8020 \
//          -e VUS=3 -e ITER=450 -e OUT=out/quota.json k6/quota.js
//
// Purpose:
//   1. Hit three nodes in turn and count total allowed requests
//   2. Count requests actually received by each node
//   3. Count allowed, rate-limited and other responses per node
// ============================================================

import http from 'k6/http';
import { Counter } from 'k6/metrics';

const allowed = new Counter('rl_allowed');
const limited = new Counter('rl_limited');
const other = new Counter('rl_other');

// Per-node request counters
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
  throw new Error(`this script requires exactly 3 nodes, got ${NODES.length}`);
}

const VUS = Number(__ENV.VUS || 30);
const TOTAL_ITER = Number(__ENV.ITER || 450);

if (TOTAL_ITER % VUS !== 0) {
  throw new Error(
    `ITER must be divisible by VUS: ITER=${TOTAL_ITER}, VUS=${VUS}`
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
  // VU is fixed to a node
  const index = (__VU - 1) % NODES.length;
  const node = NODES[index];

  // Count requests actually sent to this node
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

  console.log('\n========== Global stats ==========');
  console.log(`allowed=${count('rl_allowed')}`);
  console.log(`limited=${count('rl_limited')}`);
  console.log(`other=${count('rl_other')}`);

  console.log('\n========== Node request distribution ==========');

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
