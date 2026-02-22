import {configureStore} from '@reduxjs/toolkit';
import modelReducer from './modelSlice';
import solveReducer from './solveSlice';
import alertsReducer from './alertsSlice';
import settingsReducer from './settingsSlice';

export const store = configureStore({
  reducer: {
    model: modelReducer,
    solve: solveReducer,
    alerts: alertsReducer,
    settings: settingsReducer,
  },
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
