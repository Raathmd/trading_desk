/**
 * Solve slice — manages the current solve result and offline save queue.
 */

import {createSlice, createAsyncThunk, PayloadAction} from '@reduxjs/toolkit';
import {MMKV} from 'react-native-mmkv';
import {solve, monteCarlo, SolveResult, MonteCarloResult, isSolverAvailable, mockSolve} from '../native/SolverModule';
import {saveSolve, SaveSolveRequest} from '../services/api';

const storage = new MMKV({id: 'solve-state'});
const QUEUE_KEY = 'offline_save_queue';

// ─── Types ─────────────────────────────────────────────────────────────────────

interface PendingSave {
  id: string;
  request: SaveSolveRequest;
  attempts: number;
  lastAttempt?: string;
}

interface SolveState {
  result: SolveResult | null;
  mcResult: MonteCarloResult | null;
  solving: boolean;
  error: string | null;
  lastSolvedAt: string | null;
  savedToServer: boolean;
  saveQueue: PendingSave[];
}

// ─── Async thunks ──────────────────────────────────────────────────────────────

export const runSolve = createAsyncThunk(
  'solve/run',
  async ({descriptor, variables}: {descriptor: string; variables: number[]}) => {
    if (!isSolverAvailable()) {
      // Dev fallback
      return mockSolve();
    }
    return solve(descriptor, variables);
  },
);

export const runMonteCarlo = createAsyncThunk(
  'solve/monteCarlo',
  async ({
    descriptor,
    variables,
    nScenarios,
  }: {
    descriptor: string;
    variables: number[];
    nScenarios?: number;
  }) => {
    if (!isSolverAvailable()) {
      throw new Error('Solver not available on this platform');
    }
    return monteCarlo(descriptor, variables, nScenarios ?? 500);
  },
);

export const saveToServer = createAsyncThunk(
  'solve/saveToServer',
  async (request: SaveSolveRequest, {rejectWithValue}) => {
    try {
      return await saveSolve(request);
    } catch (e) {
      // Queue for later
      const queueItem: PendingSave = {
        id: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
        request,
        attempts: 1,
        lastAttempt: new Date().toISOString(),
      };
      const queue = loadQueue();
      queue.push(queueItem);
      persistQueue(queue);
      return rejectWithValue({queued: true, id: queueItem.id});
    }
  },
);

export const flushSaveQueue = createAsyncThunk(
  'solve/flushQueue',
  async (_, {getState}) => {
    const queue = loadQueue();
    if (queue.length === 0) return {flushed: 0};

    let flushed = 0;
    const remaining: PendingSave[] = [];

    for (const item of queue) {
      try {
        await saveSolve(item.request);
        flushed++;
      } catch {
        remaining.push({...item, attempts: item.attempts + 1, lastAttempt: new Date().toISOString()});
      }
    }

    persistQueue(remaining);
    return {flushed, remaining: remaining.length};
  },
);

// ─── Slice ─────────────────────────────────────────────────────────────────────

const solveSlice = createSlice({
  name: 'solve',
  initialState: {
    result: null,
    mcResult: null,
    solving: false,
    error: null,
    lastSolvedAt: null,
    savedToServer: false,
    saveQueue: loadQueue(),
  } as SolveState,
  reducers: {
    clearResult(state) {
      state.result = null;
      state.mcResult = null;
      state.error = null;
      state.savedToServer = false;
    },
  },
  extraReducers: builder => {
    builder
      // runSolve
      .addCase(runSolve.pending, state => {
        state.solving = true;
        state.error = null;
        state.savedToServer = false;
      })
      .addCase(runSolve.fulfilled, (state, action) => {
        state.solving = false;
        state.result = action.payload;
        state.mcResult = null;
        state.lastSolvedAt = new Date().toISOString();
      })
      .addCase(runSolve.rejected, (state, action) => {
        state.solving = false;
        state.error = action.error.message ?? 'Solve failed';
      })
      // runMonteCarlo
      .addCase(runMonteCarlo.pending, state => {
        state.solving = true;
        state.error = null;
      })
      .addCase(runMonteCarlo.fulfilled, (state, action) => {
        state.solving = false;
        state.mcResult = action.payload;
        state.result = null;
        state.lastSolvedAt = new Date().toISOString();
      })
      .addCase(runMonteCarlo.rejected, (state, action) => {
        state.solving = false;
        state.error = action.error.message ?? 'Monte Carlo failed';
      })
      // saveToServer
      .addCase(saveToServer.fulfilled, state => {
        state.savedToServer = true;
      })
      .addCase(saveToServer.rejected, (state, action) => {
        const payload = action.payload as {queued?: boolean} | undefined;
        if (payload?.queued) {
          state.saveQueue = loadQueue();
        }
      })
      // flushQueue
      .addCase(flushSaveQueue.fulfilled, state => {
        state.saveQueue = loadQueue();
      });
  },
});

export const {clearResult} = solveSlice.actions;
export default solveSlice.reducer;

// ─── Queue persistence ────────────────────────────────────────────────────────

function loadQueue(): PendingSave[] {
  try {
    const raw = storage.getString(QUEUE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function persistQueue(queue: PendingSave[]): void {
  storage.set(QUEUE_KEY, JSON.stringify(queue));
}
