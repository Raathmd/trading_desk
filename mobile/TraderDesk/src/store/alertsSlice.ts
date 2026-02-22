import {createSlice, PayloadAction} from '@reduxjs/toolkit';
import {ThresholdBreachEvent} from '../services/socket';

interface AlertsState {
  alerts: Array<ThresholdBreachEvent & {id: string; seen: boolean}>;
  unseenCount: number;
  alertsEnabled: boolean;
  subscribedGroups: string[];
}

const alertsSlice = createSlice({
  name: 'alerts',
  initialState: {
    alerts: [],
    unseenCount: 0,
    alertsEnabled: true,
    subscribedGroups: ['ammonia_domestic'],
  } as AlertsState,
  reducers: {
    addAlert(state, action: PayloadAction<ThresholdBreachEvent>) {
      const alert = {
        ...action.payload,
        id: `${action.payload.variable}-${action.payload.timestamp}`,
        seen: false,
      };
      state.alerts = [alert, ...state.alerts].slice(0, 50);
      state.unseenCount = state.alerts.filter(a => !a.seen).length;
    },
    markAllSeen(state) {
      state.alerts = state.alerts.map(a => ({...a, seen: true}));
      state.unseenCount = 0;
    },
    markSeen(state, action: PayloadAction<string>) {
      const idx = state.alerts.findIndex(a => a.id === action.payload);
      if (idx >= 0) state.alerts[idx].seen = true;
      state.unseenCount = state.alerts.filter(a => !a.seen).length;
    },
    clearAlerts(state) {
      state.alerts = [];
      state.unseenCount = 0;
    },
    setAlertsEnabled(state, action: PayloadAction<boolean>) {
      state.alertsEnabled = action.payload;
    },
    setSubscribedGroups(state, action: PayloadAction<string[]>) {
      state.subscribedGroups = action.payload;
    },
  },
});

export const {
  addAlert,
  markAllSeen,
  markSeen,
  clearAlerts,
  setAlertsEnabled,
  setSubscribedGroups,
} = alertsSlice.actions;
export default alertsSlice.reducer;
