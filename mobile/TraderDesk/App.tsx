/**
 * TraderDesk Mobile App
 *
 * Architecture:
 *   - React Native (UI)
 *   - Zig LP solver (native module — runs on device, no network needed)
 *   - Phoenix WebSocket (threshold alerts from the Elixir server)
 *   - MMKV (fast persistent storage for offline queue and cache)
 *   - Redux Toolkit (state management)
 *
 * Flow:
 *   1. On startup, fetch the latest model from GET /api/v1/mobile/model
 *   2. The model includes the binary model descriptor (base64) + variable values + metadata
 *   3. Trader can adjust variable values and tap Solve / Monte Carlo
 *   4. The Zig solver runs on-device (no network needed for solving)
 *   5. If trader wants to save: POST to /api/v1/mobile/solves (queued offline if no network)
 *   6. WebSocket keeps variable values live and fires threshold alerts
 */

import React, {useEffect} from 'react';
import {NavigationContainer} from '@react-navigation/native';
import {createBottomTabNavigator} from '@react-navigation/bottom-tabs';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {Provider, useDispatch, useSelector} from 'react-redux';
import {StatusBar, View, Text} from 'react-native';

import {store, RootState, AppDispatch} from './src/store';
import {addAlert} from './src/store/alertsSlice';
import {updateVariablesFromServer} from './src/store/modelSlice';
import {initSocket} from './src/services/socket';
import {setServerConfig} from './src/services/api';

import ModelScreen from './src/screens/ModelScreen';
import SolveResultScreen from './src/screens/SolveResultScreen';
import AlertsScreen from './src/screens/AlertsScreen';
import SettingsScreen from './src/screens/SettingsScreen';

const Tab = createBottomTabNavigator();
const Stack = createNativeStackNavigator();

// ── Tab icon (simple text-based for no icon dep) ──────────────────────────────
function TabIcon({label, color}: {label: string; color: string}) {
  return <Text style={{color, fontSize: 20}}>{label}</Text>;
}

// ── Model stack (Model → SolveResult) ─────────────────────────────────────────
function ModelStack() {
  return (
    <Stack.Navigator
      screenOptions={{
        headerStyle: {backgroundColor: '#161B22'},
        headerTintColor: '#E6EDF3',
        headerShadowVisible: false,
      }}>
      <Stack.Screen name="ModelMain" component={ModelScreen} options={{title: 'Solver Model'}} />
      <Stack.Screen
        name="SolveResult"
        component={SolveResultScreen}
        options={{title: 'Solve Result'}}
      />
    </Stack.Navigator>
  );
}

// ── Socket initializer ────────────────────────────────────────────────────────
function SocketManager() {
  const dispatch = useDispatch<AppDispatch>();
  const {serverUrl, apiToken} = useSelector((s: RootState) => s.settings);
  const {subscribedGroups} = useSelector((s: RootState) => s.alerts);

  useEffect(() => {
    if (!apiToken) return;

    setServerConfig(serverUrl, apiToken);
    const socket = initSocket(serverUrl, apiToken);

    const unsubBreach = socket.onThresholdBreachEvent(event => {
      dispatch(addAlert(event));
    });

    const unsubVars = socket.onVariablesUpdatedEvent(event => {
      dispatch(updateVariablesFromServer(event.variables));
    });

    socket.connect(subscribedGroups);

    return () => {
      unsubBreach();
      unsubVars();
      socket.disconnect();
    };
  }, [serverUrl, apiToken, subscribedGroups.join(',')]);

  return null;
}

// ── Main app ───────────────────────────────────────────────────────────────────
function AppNavigator() {
  const unseenCount = useSelector((s: RootState) => s.alerts.unseenCount);

  return (
    <>
      <SocketManager />
      <Tab.Navigator
        screenOptions={{
          tabBarStyle: {
            backgroundColor: '#161B22',
            borderTopColor: '#30363D',
          },
          tabBarActiveTintColor: '#58A6FF',
          tabBarInactiveTintColor: '#6E7681',
          headerStyle: {backgroundColor: '#161B22'},
          headerTintColor: '#E6EDF3',
          headerShadowVisible: false,
        }}>
        <Tab.Screen
          name="Model"
          component={ModelStack}
          options={{
            headerShown: false,
            tabBarIcon: ({color}) => <TabIcon label="⊞" color={color} />,
          }}
        />
        <Tab.Screen
          name="Alerts"
          component={AlertsScreen}
          options={{
            tabBarIcon: ({color}) => <TabIcon label="⚠" color={color} />,
            tabBarBadge: unseenCount > 0 ? unseenCount : undefined,
            tabBarBadgeStyle: {backgroundColor: '#F85149'},
          }}
        />
        <Tab.Screen
          name="Settings"
          component={SettingsScreen}
          options={{
            tabBarIcon: ({color}) => <TabIcon label="⚙" color={color} />,
          }}
        />
      </Tab.Navigator>
    </>
  );
}

export default function App() {
  return (
    <Provider store={store}>
      <NavigationContainer
        theme={{
          dark: true,
          colors: {
            primary: '#58A6FF',
            background: '#0D1117',
            card: '#161B22',
            text: '#E6EDF3',
            border: '#30363D',
            notification: '#F85149',
          },
        }}>
        <StatusBar barStyle="light-content" backgroundColor="#0D1117" />
        <AppNavigator />
      </NavigationContainer>
    </Provider>
  );
}
