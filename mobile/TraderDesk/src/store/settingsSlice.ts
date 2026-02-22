import {createSlice, PayloadAction} from '@reduxjs/toolkit';

interface SettingsState {
  serverUrl: string;
  apiToken: string;
  traderId: string;
  deviceId: string;
}

const settingsSlice = createSlice({
  name: 'settings',
  initialState: {
    serverUrl: 'http://localhost:4111',
    apiToken: '',
    traderId: '',
    deviceId: generateDeviceId(),
  } as SettingsState,
  reducers: {
    setServerUrl(state, action: PayloadAction<string>) {
      state.serverUrl = action.payload;
    },
    setApiToken(state, action: PayloadAction<string>) {
      state.apiToken = action.payload;
    },
    setTraderId(state, action: PayloadAction<string>) {
      state.traderId = action.payload;
    },
  },
});

export const {setServerUrl, setApiToken, setTraderId} = settingsSlice.actions;
export default settingsSlice.reducer;

function generateDeviceId(): string {
  return `mobile-${Math.random().toString(36).slice(2)}-${Date.now()}`;
}
