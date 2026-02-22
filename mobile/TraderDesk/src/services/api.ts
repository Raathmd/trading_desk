/**
 * TradingDesk Mobile API Client
 *
 * Talks to the Elixir server's /api/v1/mobile endpoints.
 * All calls include the Bearer token from secure storage.
 */

import {MMKV} from 'react-native-mmkv';

const storage = new MMKV({id: 'trader-desk-api'});

export type ProductGroup =
  | 'ammonia_domestic'
  | 'ammonia_international'
  | 'uan'
  | 'urea'
  | 'sulphur_international'
  | 'petcoke';

export type ObjectiveMode =
  | 'max_profit'
  | 'min_cost'
  | 'max_roi'
  | 'cvar_adjusted'
  | 'min_risk';

export interface VariableMeta {
  key: string;
  label: string;
  unit: string;
  min: number;
  max: number;
  step: number;
  source: string;
  group: string;
  type: 'continuous' | 'boolean';
}

export interface RouteLabel {
  index: number;
  key: string;
  label: string;
  origin?: string;
  destination?: string;
  unit_capacity: number;
  typical_transit_days: number;
}

export interface ConstraintLabel {
  index: number;
  type: string;
  label: string;
  bound_variable?: string;
}

export interface ModelPayload {
  product_group: ProductGroup;
  timestamp: string;
  variables: Record<string, number | boolean>;
  metadata: VariableMeta[];
  descriptor: string; // base64-encoded binary model descriptor
  descriptor_byte_length: number;
  variable_count: number;
  routes: RouteLabel[];
  constraints: ConstraintLabel[];
  objective: ObjectiveMode;
  lambda: number;
  profit_floor: number;
}

export interface ThresholdPayload {
  product_group: ProductGroup;
  thresholds: Record<string, number>;
  enabled: boolean;
  timestamp: string;
}

export interface SolveResultPayload {
  status: 'optimal' | 'infeasible' | 'error';
  profit: number;
  tons: number;
  cost: number;
  roi: number;
  route_tons: number[];
  route_profits: number[];
  margins: number[];
  shadow_prices: number[];
}

export interface SaveSolveRequest {
  product_group: ProductGroup;
  variables: Record<string, number | boolean>;
  result: SolveResultPayload;
  mode: 'solve' | 'monte_carlo';
  trader_id: string;
  solved_at: string;
  device_id: string;
}

// ─── Configuration ───────────────────────────────────────────────────────────

const DEFAULT_BASE_URL = 'http://localhost:4111';

function getBaseUrl(): string {
  return storage.getString('server_url') ?? DEFAULT_BASE_URL;
}

function getToken(): string {
  return storage.getString('api_token') ?? '';
}

export function setServerConfig(url: string, token: string): void {
  storage.set('server_url', url);
  storage.set('api_token', token);
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

async function apiFetch<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const url = `${getBaseUrl()}${path}`;

  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      ...(options.headers ?? {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`API ${response.status}: ${body}`);
  }

  return response.json() as Promise<T>;
}

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Fetch the full model payload from the server.
 * Returns variables, metadata, binary descriptor (base64), and layout info.
 */
export async function fetchModel(
  productGroup: ProductGroup = 'ammonia_domestic',
  objective: ObjectiveMode = 'max_profit',
  lambda = 0.0,
  profitFloor = 0.0,
): Promise<ModelPayload> {
  const params = new URLSearchParams({
    product_group: productGroup,
    objective,
    lambda: String(lambda),
    profit_floor: String(profitFloor),
  });
  return apiFetch<ModelPayload>(`/api/v1/mobile/model?${params}`);
}

/**
 * Fetch just the binary model descriptor (lighter call after initial load).
 */
export async function fetchDescriptor(
  productGroup: ProductGroup,
  objective: ObjectiveMode,
  lambda = 0.0,
  profitFloor = 0.0,
): Promise<{descriptor: string; byte_length: number; timestamp: string}> {
  const params = new URLSearchParams({
    product_group: productGroup,
    objective,
    lambda: String(lambda),
    profit_floor: String(profitFloor),
  });
  return apiFetch(`/api/v1/mobile/model/descriptor?${params}`);
}

/**
 * Fetch current threshold config for a product group.
 */
export async function fetchThresholds(
  productGroup: ProductGroup,
): Promise<ThresholdPayload> {
  return apiFetch(`/api/v1/mobile/thresholds?product_group=${productGroup}`);
}

/**
 * Save a device-side solve result to the server.
 */
export async function saveSolve(request: SaveSolveRequest): Promise<{ok: boolean; audit_id: string}> {
  return apiFetch('/api/v1/mobile/solves', {
    method: 'POST',
    body: JSON.stringify(request),
  });
}
