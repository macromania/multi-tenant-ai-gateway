// Open-loop chat-completions load for the tenancy comparison. One k6 scenario per stream.
// The plan (/etc/k6/plan/plan.json) and keys (/etc/k6/keys/<name>) are mounted by scripts/load.sh.
// Streams with records print "START {json}" when a request begins and "PROBE {json}" when it ends,
// so a request cut off by an early stop is still known ("censored"). handleSummary prints
// "K6_SUMMARY {json}". Every request goes to the mock, directly or through a gateway.
import http from 'k6/http';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';

const plan = JSON.parse(open('/etc/k6/plan/plan.json'));
const keys = {};
const streams = {};
// Bodies above this size are built per request instead of kept by every VU for the whole run.
const LARGE_BODY_CHARS = 8192;
function body(stream) {
  return JSON.stringify({
    model: stream.model || 'mock-chat',
    messages: [{ role: 'user', content: 'x'.repeat(stream.prompt_chars || 40) }],
    max_completion_tokens: stream.max_completion_tokens || 16,
  });
}
for (const stream of plan.streams) {
  keys[stream.key] = open(`/etc/k6/keys/${stream.key}`).trim();
  stream.expected_owner = stream.expected_owner || stream.tenant;
  if ((stream.prompt_chars || 40) <= LARGE_BODY_CHARS) stream.body = body(stream);
  streams[stream.name] = stream;
}

const verdicts = new Counter('mtag_verdicts');
// HTTP statuses per stream, so a run can prove which refusals it saw (0 is a transport error).
const statuses = new Counter('mtag_statuses');
const STATUS_CLASSES = ['0', '200', '401', '404', '429', '500', '502', '503', 'other'];
function statusClass(status) {
  const text = String(status);
  return STATUS_CLASSES.indexOf(text) >= 0 ? text : 'other';
}

function seconds(value) {
  const match = /^([0-9]+)(s|m)$/.exec(value || '60s');
  return Number(match[1]) * (match[2] === 'm' ? 60 : 1);
}

// Streams with records must keep sending while the system slows down, so they get enough VUs for
// every request to run to its timeout. Other streams are sized for their mock latency.
function vus(stream) {
  let lifetime;
  if (stream.records) {
    lifetime = seconds(stream.timeout) + 1;
  } else {
    const latencies = [stream.latency_ms || 100].concat((stream.latency_schedule || []).map((step) => step.latency_ms));
    lifetime = Math.max(...latencies) / 1000 + 0.5;
  }
  const needed = Math.ceil(stream.rate * lifetime * 1.2) + 2;
  const cap = stream.max_vus || 4000;
  return { preAllocatedVUs: Math.min(needed, cap), maxVUs: Math.min(needed * 2, cap) };
}

const scenarios = {};
const thresholds = {};
for (const stream of plan.streams) {
  scenarios[stream.name] = Object.assign({
    executor: 'constant-arrival-rate',
    rate: stream.rate,
    timeUnit: '1s',
    duration: stream.duration,
    startTime: stream.start_delay || '0s',
    gracefulStop: stream.graceful_stop || '65s',
    exec: 'run',
    env: { STREAM: stream.name },
    tags: { stream: stream.name, tenant: stream.tenant },
  }, vus(stream));
  // Thresholds that always pass make k6 report each stream's own numbers in the summary.
  thresholds[`http_reqs{stream:${stream.name}}`] = ['count>=0'];
  thresholds[`http_req_duration{stream:${stream.name}}`] = ['max>=0'];
  thresholds[`http_req_failed{stream:${stream.name}}`] = ['rate>=0'];
  thresholds[`iterations{scenario:${stream.name}}`] = ['count>=0'];
  thresholds[`dropped_iterations{scenario:${stream.name}}`] = ['count>=0'];
  for (const verdict of ['verified', 'leak', 'blocked', 'unverifiable', 'failed']) {
    thresholds[`mtag_verdicts{stream:${stream.name},verdict:${verdict}}`] = ['count>=0'];
  }
  for (const status of STATUS_CLASSES) {
    thresholds[`mtag_statuses{stream:${stream.name},status:${status}}`] = ['count>=0'];
  }
}

export const options = {
  scenarios,
  thresholds,
  discardResponseBodies: true,
  summaryTrendStats: ['p(50)', 'p(95)', 'p(99)', 'max'],
  tags: { cluster: plan.cluster, run_id: plan.run_id },
};

function latencyFor(stream) {
  let latency = stream.latency_ms;
  const elapsed = (Date.now() - exec.scenario.startTime) / 1000;
  for (const step of stream.latency_schedule || []) {
    if (elapsed >= step.at_s) latency = step.latency_ms;
  }
  return latency;
}

function verdictFor(stream, response, probeId) {
  const owner = response.headers['X-Mock-Key-Owner'];
  const echoed = response.headers['X-Mock-Probe-Id'];
  if (owner !== undefined) {
    if (owner !== 'none' && owner !== stream.expected_owner) return 'leak';
    if (echoed !== probeId) return 'leak';
    return response.status === 200 ? 'verified' : 'failed';
  }
  if (response.status === 200) return 'unverifiable';
  if (response.status >= 400 && response.status < 500) return 'blocked';
  return 'failed';
}

export function run() {
  const stream = streams[__ENV.STREAM];
  const probeId = `${stream.name}-${exec.vu.idInTest}-${exec.vu.iterationInScenario}`;
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${keys[stream.key]}`, 'x-probe-id': probeId };
  const latency = latencyFor(stream);
  if (latency !== undefined && latency !== null) headers['x-mock-latency-ms'] = String(latency);
  if (stream.forged_tenant) headers['x-tenant'] = stream.forged_tenant;
  if (stream.corrupt_id) headers['x-mock-corrupt-id'] = '1';
  const start = Date.now();
  if (stream.records) console.log('START ' + JSON.stringify({ stream: stream.name, probe_id: probeId, start_ms: start }));
  const response = http.post(stream.url, stream.body || body(stream), { headers, timeout: stream.timeout || '60s' });
  const verdict = verdictFor(stream, response, probeId);
  verdicts.add(1, { verdict });
  statuses.add(1, { status: statusClass(response.status) });
  if (stream.records) {
    console.log('PROBE ' + JSON.stringify({
      stream: stream.name, tenant: stream.tenant, gateway: stream.gateway || null,
      sent_tenant_header: stream.forged_tenant || null, start_ms: start, duration_ms: Date.now() - start,
      status: response.status, error_code: response.error_code || 0, probe_id: probeId,
      echoed_probe_id: response.headers['X-Mock-Probe-Id'] || null,
      key_owner: response.headers['X-Mock-Key-Owner'] || null, latency_ms: latency === undefined ? null : latency,
      verdict,
    }));
  }
}

export function handleSummary(data) {
  const values = (name) => (data.metrics[name] ? data.metrics[name].values : null);
  const perStream = {};
  for (const stream of plan.streams) {
    const verdictCounts = {};
    for (const verdict of ['verified', 'leak', 'blocked', 'unverifiable', 'failed']) {
      const found = values(`mtag_verdicts{stream:${stream.name},verdict:${verdict}}`);
      verdictCounts[verdict] = found ? found.count : 0;
    }
    const statusCounts = {};
    for (const status of STATUS_CLASSES) {
      const found = values(`mtag_statuses{stream:${stream.name},status:${status}}`);
      if (found && found.count > 0) statusCounts[status] = found.count;
    }
    const requests = values(`http_reqs{stream:${stream.name}}`);
    const iterations = values(`iterations{scenario:${stream.name}}`);
    const dropped = values(`dropped_iterations{scenario:${stream.name}}`);
    perStream[stream.name] = {
      tenant: stream.tenant, role: stream.role || null, target_rate: stream.rate, duration: stream.duration,
      recorded: Boolean(stream.records),
      requests: requests ? requests.count : 0, iterations: iterations ? iterations.count : 0,
      dropped_iterations: dropped ? dropped.count : 0,
      failed_rate: (values(`http_req_failed{stream:${stream.name}}`) || { rate: 0 }).rate,
      duration_ms: values(`http_req_duration{stream:${stream.name}}`), verdicts: verdictCounts,
      statuses: statusCounts,
    };
  }
  const summary = { run_id: plan.run_id, cluster: plan.cluster, streams: perStream,
    vus_max: (values('vus_max') || { max: 0 }).max, state: data.state };
  return { stdout: 'K6_SUMMARY ' + JSON.stringify(summary) + '\n' };
}
