/**
 * Model slice — stores the current model payload from the server.
 *
 * The "model" is everything needed to run a solve:
 *   - variables (current values)
 *   - metadata (labels, units, min/max for each variable)
 *   - descriptor (base64 binary passed to the Zig solver)
 *   - routes + constraints layout
 */

import {createSlice, createAsyncThunk, PayloadAction} from '@reduxjs/toolkit';
import {MMKV} from 'react-native-mmkv';
import {fetchModel, ModelPayload, ProductGroup, ObjectiveMode} from '../services/api';

const storage = new MMKV({id: 'model-cache'});

interface ModelState {
  payload: ModelPayload | null;
  loading: boolean;
  error: string | null;
  lastFetched: string | null;
  // Local overrides — trader can adjust variables before solving
  variableOverrides: Record<string, number | boolean>;
  selectedProductGroup: ProductGroup;
  selectedObjective: ObjectiveMode;
  lambda: number;
  profitFloor: number;
}

const initialState: ModelState = {
  payload: tryLoadCached(),
  loading: false,
  error: null,
  lastFetched: null,
  variableOverrides: {},
  selectedProductGroup: 'ammonia_domestic',
  selectedObjective: 'max_profit',
  lambda: 0.0,
  profitFloor: 0.0,
};

// ─── Async thunk ──────────────────────────────────────────────────────────────

export const loadModel = createAsyncThunk(
  'model/load',
  async (
    args: {
      productGroup?: ProductGroup;
      objective?: ObjectiveMode;
      lambda?: number;
      profitFloor?: number;
    } = {},
  ) => {
    const payload = await fetchModel(
      args.productGroup ?? 'ammonia_domestic',
      args.objective ?? 'max_profit',
      args.lambda ?? 0.0,
      args.profitFloor ?? 0.0,
    );
    // Cache for offline use
    storage.set('cached_model', JSON.stringify(payload));
    storage.set('cache_ts', new Date().toISOString());
    return payload;
  },
);

// ─── Slice ────────────────────────────────────────────────────────────────────

const modelSlice = createSlice({
  name: 'model',
  initialState,
  reducers: {
    setVariableOverride(
      state,
      action: PayloadAction<{key: string; value: number | boolean}>,
    ) {
      state.variableOverrides[action.payload.key] = action.payload.value;
    },
    resetOverrides(state) {
      state.variableOverrides = {};
    },
    setProductGroup(state, action: PayloadAction<ProductGroup>) {
      state.selectedProductGroup = action.payload;
      state.variableOverrides = {};
    },
    setObjective(state, action: PayloadAction<ObjectiveMode>) {
      state.selectedObjective = action.payload;
    },
    setLambda(state, action: PayloadAction<number>) {
      state.lambda = action.payload;
    },
    setProfitFloor(state, action: PayloadAction<number>) {
      state.profitFloor = action.payload;
    },
    updateVariablesFromServer(
      state,
      action: PayloadAction<Record<string, number | boolean>>,
    ) {
      if (state.payload) {
        state.payload.variables = action.payload;
      }
    },
  },
  extraReducers: builder => {
    builder
      .addCase(loadModel.pending, state => {
        state.loading = true;
        state.error = null;
      })
      .addCase(loadModel.fulfilled, (state, action) => {
        state.loading = false;
        state.payload = action.payload;
        state.lastFetched = new Date().toISOString();
        state.variableOverrides = {};
      })
      .addCase(loadModel.rejected, (state, action) => {
        state.loading = false;
        state.error = action.error.message ?? 'Failed to load model';
      });
  },
});

export const {
  setVariableOverride,
  resetOverrides,
  setProductGroup,
  setObjective,
  setLambda,
  setProfitFloor,
  updateVariablesFromServer,
} = modelSlice.actions;

// ─── Selectors ────────────────────────────────────────────────────────────────

/** Merged variables: server values with trader overrides applied */
export function selectEffectiveVariables(state: {model: ModelState}): Record<string, number | boolean> {
  const base = state.model.payload?.variables ?? {};
  return {...base, ...state.model.variableOverrides};
}

/** Variables as a flat float array in frame order (for the Zig solver) */
export function selectVariablesArray(state: {model: ModelState}): number[] {
  const effective = selectEffectiveVariables(state);
  const meta = state.model.payload?.metadata ?? [];
  return meta.map(m => {
    const val = effective[m.key];
    if (typeof val === 'boolean') return val ? 1.0 : 0.0;
    return (val as number) ?? 0.0;
  });
}

export default modelSlice.reducer;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function tryLoadCached(): ModelPayload | null {
  try {
    const raw = storage.getString('cached_model');
    return raw ? (JSON.parse(raw) as ModelPayload) : null;
  } catch {
    return null;
  }
}
