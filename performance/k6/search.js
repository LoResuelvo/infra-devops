import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend, Rate } from 'k6/metrics';
import { htmlReport } from './vendor/k6-reporter-3.0.4.js';

const config = JSON.parse(open('/private/config.json'));
const run = JSON.parse(open('/private/plan.json'));
const operationDuration = new Trend('operation_ms', true);
const operationFailures = new Rate('operation_failed');
const completedOperations = new Counter('operations');
const startedOperations = new Counter('operations_started');
const failureKinds = new Counter('failure_kinds');
let failureKind = 'none';

export const options = {
  scenarios: { search: run.executor },
  maxRedirects: 0,
  // No exportar URL, cookies ni contenido de respuestas.
  systemTags: ['status', 'method', 'name', 'scenario'],
  summaryTrendStats: ['med', 'p(95)', 'p(99)'],
  thresholds: {
    operation_ms: [`p(95)<${run.p95_limit_ms || 1500}`],
    operation_failed: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
    dropped_iterations: ['count==0'],
  },
};

function abortInvalidMeasurement(response) {
  const body = response.body || '';
  const invalidSession = run.scenario === 'web' && (
    response.status === 401 || response.status === 403 ||
    (response.status >= 300 && response.status < 400) ||
    body.includes('NEXT_REDIRECT') || body.includes('/auth/login')
  );
  if (run.scenario === 'web' && invalidSession) {
    exec.test.abort('web_session_invalid');
  }

  const cacheStatus = (response.headers['Cf-Cache-Status'] || '').toUpperCase();
  const servedFromCache = ['HIT', 'STALE', 'UPDATING', 'REVALIDATED'].includes(cacheStatus);
  const challenged = response.headers['Cf-Mitigated'] === 'challenge';
  if (servedFromCache || challenged || response.status === 429) {
    exec.test.abort('edge_invalidates_measurement');
  }
}

function get(path, metricName) {
  const headers = {
    'User-Agent': 'LoResuelvo performance campaign',
    'Cache-Control': 'no-cache',
  };
  if (run.scenario === 'web') {
    headers.Cookie = config.cookie;
  }
  if (run.profile === 'availability') {
    // Remove edge affinity without changing the explicit consumer session.
    http.cookieJar().clear(config[`${run.scenario}_url`]);
  }
  const response = http.get(config[`${run.scenario}_url`] + path, {
    redirects: 0,
    timeout: '10s',
    headers,
    tags: { name: metricName },
  });
  if (response.status === 0) failureKind = 'transport';
  else if (response.status >= 500) failureKind = 'http_5xx';
  else if (response.status !== 200) failureKind = 'http_other';
  abortInvalidMeasurement(response);
  return response;
}

function searchApi(category) {
  const categoriesResponse = get('/categories', 'categories');
  const providersResponse = get(`/providers?category_id=${category.id}`, 'providers');

  try {
    const providers = providersResponse.json();
    return (
      categoriesResponse.status === 200 && providersResponse.status === 200 &&
      categoriesResponse.json().some(item => item.id === category.id && item.name === category.name) &&
      Array.isArray(providers) && providers.length >= category.min_providers &&
      providers.every(item => Number.isInteger(item.id) && item.category_name === category.name) &&
      category.provider_ids.every(id => providers.some(item => item.id === id))
    );
  } catch (_) {
    return false;
  }
}

function searchWeb(category) {
  const response = get(`/consumidor/buscar?category_id=${category.id}`, 'search_html');
  const body = response.body || '';
  return (
    response.status === 200 &&
    (response.headers['Content-Type'] || '').includes('text/html') &&
    body.includes('provider-card') &&
    category.web_markers.every(marker => body.includes(marker))
  );
}

export default function search() {
  const categoryIndex = exec.scenario.iterationInTest % config.categories.length;
  const category = config.categories[categoryIndex];
  const startedAt = Date.now();
  failureKind = 'none';
  if (run.profile === 'availability') startedOperations.add(1);
  const success = run.scenario === 'api' ? searchApi(category) : searchWeb(category);

  const elapsedSeconds = (Date.now() - exec.scenario.startTime) / 1000;
  const tags = {
    failed: String(!success),
    window: String(Math.floor(elapsedSeconds / 15)),
  };
  if (run.profile === 'availability') {
    tags.started_ms = String(startedAt);
    tags.failure_kind = success ? 'none' : (failureKind === 'none' ? 'content' : failureKind);
    if (!success) failureKinds.add(1, { kind: tags.failure_kind });
  }
  operationDuration.add(Date.now() - startedAt, tags);
  operationFailures.add(!success);
  completedOperations.add(1);
}

export function handleSummary(data) {
  return {
    '/out/k6-summary.json': JSON.stringify(data),
    '/out/summary.html': htmlReport(data, { title: 'LoResuelvo — resumen de lectura' }),
  };
}
