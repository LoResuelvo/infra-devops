// Matriz y executors de k6. Este archivo también se ejecuta sin red para
// entregar el plan a Python; no realiza solicitudes ni carga durante ese paso.
const EXPLORATION_RATES = [1, 2, 5, 10, 20, 40];
const VALIDATED_RATES = EXPLORATION_RATES;
const ARRIVAL_OPTIONS = {
  preAllocatedVUs: 200,
  maxVUs: 200,
  gracefulStop: '10s',
};

export function buildPlan(profile, rate) {
  if (['sustained', 'spike'].includes(profile) && !VALIDATED_RATES.includes(rate)) {
    throw new Error('Use R confirmed by exploration');
  }

  // Cada entrada contiene [executor, segundos de carga, tasa de referencia].
  if (profile === 'smoke') {
    return [[{
      executor: 'constant-vus',
      vus: 1,
      duration: '30s',
      gracefulStop: '10s',
    }, 30, null]];
  }

  if (profile === 'spike') {
    // R llegadas cada 4 s representa R/4 op/s sin redondear la base.
    return [[{
      ...ARRIVAL_OPTIONS,
      executor: 'ramping-arrival-rate',
      startRate: rate,
      timeUnit: '4s',
      stages: [
        { duration: '60s', target: rate },
        { duration: '0s', target: 4 * rate },
        { duration: '30s', target: 4 * rate },
        { duration: '0s', target: rate },
        { duration: '90s', target: rate },
      ],
    }, 180, rate]];
  }

  let rates;
  if (profile === 'warmup') {
    rates = [1];
  } else if (profile === 'explore') {
    rates = rate ? [rate] : EXPLORATION_RATES;
  } else {
    rates = [rate, rate];
  }

  const seconds = profile === 'sustained' ? 180 : 60;
  return rates.map(offeredRate => [{
    ...ARRIVAL_OPTIONS,
    executor: 'constant-arrival-rate',
    rate: offeredRate,
    timeUnit: '1s',
    duration: `${seconds}s`,
  }, seconds, offeredRate]);
}

export const options = { vus: 1, iterations: 1 };
export default function () {}

export function handleSummary() {
  const plan = buildPlan(__ENV.PROFILE, Number(__ENV.RATE));
  return { stdout: JSON.stringify(plan) };
}
