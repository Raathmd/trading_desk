/**
 * SolverModule — React Native interface to the Zig LP solver shared library.
 *
 * The Zig library exposes:
 *   - trading_solve(model_descriptor, model_len, variables, n_vars, out) → status
 *   - trading_monte_carlo(descriptor, len, center, n_vars, n_scenarios, out) → status
 *   - trading_solver_version() → version string
 *
 * On iOS: called via the NativeSolverModule Swift wrapper (uses UnsafePointer FFI).
 * On Android: called via JNI in SolverModule.java / SolverModule.kt.
 *
 * This TypeScript file provides the JS-side interface.
 */

import {NativeModules, Platform} from 'react-native';

const {TradingSolver} = NativeModules;

export interface SolveResult {
  status: 'optimal' | 'infeasible' | 'error' | 'bad_input';
  profit: number;
  tons: number;
  cost: number;
  roi: number;
  nRoutes: number;
  routeTons: number[];
  routeProfits: number[];
  margins: number[];
  nConstraints: number;
  shadowPrices: number[];
}

export interface MonteCarloResult {
  status: 'ok' | 'error';
  nScenarios: number;
  nFeasible: number;
  nInfeasible: number;
  mean: number;
  stddev: number;
  p5: number;
  p25: number;
  p50: number;
  p75: number;
  p95: number;
  min: number;
  max: number;
  sensitivityIdx: number[];
  sensitivityCorr: number[];
  signal: 'strong_go' | 'go' | 'cautious' | 'weak' | 'no_go';
}

// Status code → string
const STATUS_MAP: Record<number, SolveResult['status']> = {
  0: 'optimal',
  1: 'infeasible',
  2: 'error',
  3: 'bad_input',
};

// ─── Native module wrapper ────────────────────────────────────────────────────

/**
 * Run the LP solver on the device.
 *
 * @param descriptorBase64  base64-encoded binary model descriptor from the server
 * @param variables         current variable values in frame order
 * @returns SolveResult
 */
export async function solve(
  descriptorBase64: string,
  variables: number[],
): Promise<SolveResult> {
  if (!TradingSolver) {
    throw new Error('TradingSolver native module not available on this platform');
  }

  const raw: {
    status: number;
    profit: number;
    tons: number;
    cost: number;
    roi: number;
    nRoutes: number;
    routeTons: number[];
    routeProfits: number[];
    margins: number[];
    nConstraints: number;
    shadowPrices: number[];
  } = await TradingSolver.solve(descriptorBase64, variables);

  return {
    ...raw,
    status: STATUS_MAP[raw.status] ?? 'error',
  };
}

/**
 * Run Monte Carlo simulation on the device.
 *
 * @param descriptorBase64  base64-encoded binary model descriptor
 * @param centerVariables   center-point variable values
 * @param nScenarios        number of MC scenarios (recommend 500 on mobile)
 */
export async function monteCarlo(
  descriptorBase64: string,
  centerVariables: number[],
  nScenarios = 500,
): Promise<MonteCarloResult> {
  if (!TradingSolver) {
    throw new Error('TradingSolver native module not available');
  }

  const raw: Omit<MonteCarloResult, 'signal'> & {status: number} =
    await TradingSolver.monteCarlo(descriptorBase64, centerVariables, nScenarios);

  const signal = classifySignal(raw.p5, raw.p25, raw.p50);

  return {
    ...raw,
    status: raw.status === 0 ? 'ok' : 'error',
    signal,
  };
}

/**
 * Get the solver library version string.
 */
export async function getSolverVersion(): Promise<string> {
  if (!TradingSolver) return 'native module unavailable';
  return TradingSolver.getVersion();
}

// ─── Signal classification ────────────────────────────────────────────────────
// Mirrors the Elixir server's classify_signal/3 logic.
// Thresholds can be fetched from the server and passed in; these defaults match.

function classifySignal(p5: number, p25: number, p50: number): MonteCarloResult['signal'] {
  if (p5 > 50_000) return 'strong_go';
  if (p25 > 50_000) return 'go';
  if (p50 > 0) return 'cautious';
  if (p50 > -10_000) return 'weak';
  return 'no_go';
}

// ─── Mock for dev/testing without a device ───────────────────────────────────

export function isSolverAvailable(): boolean {
  return !!TradingSolver;
}

/**
 * Mock solve result — used in Storybook / unit tests where the native module
 * is not available.
 */
export function mockSolve(): SolveResult {
  return {
    status: 'optimal',
    profit: 127_500,
    tons: 4500,
    cost: 1_530_000,
    roi: 8.33,
    nRoutes: 2,
    routeTons: [1500, 3000],
    routeProfits: [45_000, 82_500],
    margins: [30.0, 27.5],
    nConstraints: 4,
    shadowPrices: [0, 0, 5.2, 0],
  };
}
