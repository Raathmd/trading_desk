/**
 * SettingsScreen — configure server connection, alerts, and product groups.
 */

import React, {useState, useEffect} from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  Switch,
  Alert,
} from 'react-native';
import {useDispatch, useSelector} from 'react-redux';
import {RootState, AppDispatch} from '../store';
import {setServerUrl, setApiToken, setTraderId} from '../store/settingsSlice';
import {setAlertsEnabled, setSubscribedGroups} from '../store/alertsSlice';
import {setServerConfig} from '../services/api';
import {initSocket, getSocket} from '../services/socket';
import {flushSaveQueue} from '../store/solveSlice';
import {getSolverVersion} from '../native/SolverModule';

const PRODUCT_GROUPS = [
  'ammonia_domestic',
  'ammonia_international',
  'uan',
  'urea',
  'sulphur_international',
  'petcoke',
];

export default function SettingsScreen() {
  const dispatch = useDispatch<AppDispatch>();
  const {serverUrl, apiToken, traderId, deviceId} = useSelector((s: RootState) => s.settings);
  const {alertsEnabled, subscribedGroups} = useSelector((s: RootState) => s.alerts);
  const {saveQueue} = useSelector((s: RootState) => s.solve);

  const [localUrl, setLocalUrl] = useState(serverUrl);
  const [localToken, setLocalToken] = useState(apiToken);
  const [localTrader, setLocalTrader] = useState(traderId);
  const [solverVer, setSolverVer] = useState('');
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    getSolverVersion().then(setSolverVer);
    const socket = getSocket();
    if (socket) {
      const unsub = socket.onConnectionChanged(setConnected);
      return unsub;
    }
  }, []);

  const onSaveConnection = () => {
    dispatch(setServerUrl(localUrl));
    dispatch(setApiToken(localToken));
    dispatch(setTraderId(localTrader));
    setServerConfig(localUrl, localToken);

    // Reconnect socket
    const socket = initSocket(localUrl, localToken);
    socket.connect(subscribedGroups);
    socket.onConnectionChanged(setConnected);

    Alert.alert('Saved', 'Connection settings saved. Reconnecting…');
  };

  const onTestConnection = async () => {
    try {
      const res = await fetch(`${localUrl}/api/sap/status`, {
        headers: {Authorization: `Bearer ${localToken}`},
      });
      Alert.alert('Connected', `Server responded: ${res.status}`);
    } catch (e: any) {
      Alert.alert('Connection Failed', e.message);
    }
  };

  const onFlushQueue = () => {
    dispatch(flushSaveQueue());
    Alert.alert('Sync', 'Attempting to sync offline saves…');
  };

  const toggleGroup = (group: string) => {
    const updated = subscribedGroups.includes(group)
      ? subscribedGroups.filter(g => g !== group)
      : [...subscribedGroups, group];
    dispatch(setSubscribedGroups(updated));

    const socket = getSocket();
    if (socket && connected) {
      // Re-join with updated groups
      socket.disconnect();
      socket.connect(updated);
    }
  };

  return (
    <ScrollView style={styles.root} contentContainerStyle={styles.content}>
      {/* ── Connection ────────────────────────────────────────── */}
      <SectionHeader title="Server Connection" />
      <View style={styles.card}>
        <LabeledInput
          label="Server URL"
          value={localUrl}
          onChange={setLocalUrl}
          placeholder="http://localhost:4111"
          autoCapitalize="none"
        />
        <LabeledInput
          label="API Token"
          value={localToken}
          onChange={setLocalToken}
          placeholder="Bearer token from admin"
          autoCapitalize="none"
          secureTextEntry
        />
        <LabeledInput
          label="Trader ID"
          value={localTrader}
          onChange={setLocalTrader}
          placeholder="trader@example.com"
          autoCapitalize="none"
        />

        <View style={styles.row}>
          <View style={[styles.statusDot, {backgroundColor: connected ? '#3FB950' : '#8B949E'}]} />
          <Text style={styles.statusText}>{connected ? 'Connected' : 'Disconnected'}</Text>
        </View>

        <View style={styles.btnRow}>
          <TouchableOpacity style={[styles.btn, styles.testBtn]} onPress={onTestConnection}>
            <Text style={styles.btnText}>Test</Text>
          </TouchableOpacity>
          <TouchableOpacity style={[styles.btn, styles.saveBtn]} onPress={onSaveConnection}>
            <Text style={styles.btnText}>Save & Connect</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* ── Alerts ───────────────────────────────────────────── */}
      <SectionHeader title="Threshold Alerts" />
      <View style={styles.card}>
        <View style={styles.toggleRow}>
          <Text style={styles.toggleLabel}>Enable Alerts</Text>
          <Switch
            value={alertsEnabled}
            onValueChange={v => dispatch(setAlertsEnabled(v))}
            trackColor={{false: '#30363D', true: '#3FB950'}}
          />
        </View>

        <Text style={styles.subLabel}>Alert when these product groups breach thresholds:</Text>
        {PRODUCT_GROUPS.map(pg => (
          <View key={pg} style={styles.toggleRow}>
            <Text style={styles.toggleLabel}>{pg.replace(/_/g, ' ')}</Text>
            <Switch
              value={subscribedGroups.includes(pg)}
              onValueChange={() => toggleGroup(pg)}
              disabled={!alertsEnabled}
              trackColor={{false: '#30363D', true: '#58A6FF'}}
            />
          </View>
        ))}
      </View>

      {/* ── Offline Queue ────────────────────────────────────── */}
      <SectionHeader title="Offline Sync" />
      <View style={styles.card}>
        <View style={styles.row}>
          <Text style={styles.label}>Pending saves:</Text>
          <Text style={styles.value}>{saveQueue.length}</Text>
        </View>
        <TouchableOpacity
          style={[styles.btn, styles.syncBtn, saveQueue.length === 0 && styles.btnDisabled]}
          onPress={onFlushQueue}
          disabled={saveQueue.length === 0}>
          <Text style={styles.btnText}>Sync Now</Text>
        </TouchableOpacity>
      </View>

      {/* ── Device Info ───────────────────────────────────────── */}
      <SectionHeader title="Device Info" />
      <View style={styles.card}>
        <View style={styles.row}>
          <Text style={styles.label}>Device ID:</Text>
          <Text style={styles.valueSmall}>{deviceId}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Solver:</Text>
          <Text style={styles.valueSmall}>{solverVer || 'unknown'}</Text>
        </View>
      </View>

      <View style={{height: 40}} />
    </ScrollView>
  );
}

function SectionHeader({title}: {title: string}) {
  return <Text style={styles.sectionHeader}>{title.toUpperCase()}</Text>;
}

function LabeledInput({label, ...props}: {label: string} & React.ComponentProps<typeof TextInput>) {
  return (
    <View style={styles.inputGroup}>
      <Text style={styles.inputLabel}>{label}</Text>
      <TextInput style={styles.input} placeholderTextColor="#6E7681" {...props} />
    </View>
  );
}

const COLORS = {
  bg: '#0D1117',
  card: '#161B22',
  border: '#30363D',
  text: '#E6EDF3',
  muted: '#8B949E',
  accent: '#58A6FF',
  green: '#3FB950',
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: COLORS.bg},
  content: {padding: 16},
  sectionHeader: {
    color: COLORS.muted, fontSize: 11, fontWeight: '700',
    letterSpacing: 1, marginTop: 20, marginBottom: 8, marginLeft: 4,
    textTransform: 'uppercase',
  },
  card: {
    backgroundColor: COLORS.card, borderRadius: 10,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 12,
  },
  inputGroup: {gap: 4},
  inputLabel: {color: COLORS.muted, fontSize: 12},
  input: {
    color: COLORS.text, fontSize: 14, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: 8, padding: 10, backgroundColor: COLORS.bg,
  },
  row: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  label: {color: COLORS.muted, fontSize: 13},
  value: {color: COLORS.text, fontSize: 15, fontWeight: '600'},
  valueSmall: {color: COLORS.text, fontSize: 11, flex: 1, textAlign: 'right'},
  subLabel: {color: COLORS.muted, fontSize: 12},
  toggleRow: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  toggleLabel: {color: COLORS.text, fontSize: 14},
  statusDot: {width: 8, height: 8, borderRadius: 4, marginRight: 6},
  statusText: {color: COLORS.muted, fontSize: 13},
  btnRow: {flexDirection: 'row', gap: 8},
  btn: {flex: 1, paddingVertical: 12, borderRadius: 8, alignItems: 'center'},
  testBtn: {backgroundColor: '#21262D', borderWidth: 1, borderColor: COLORS.border},
  saveBtn: {backgroundColor: '#1F6FEB'},
  syncBtn: {backgroundColor: COLORS.accent},
  btnDisabled: {opacity: 0.4},
  btnText: {color: '#fff', fontWeight: '600', fontSize: 14},
});
