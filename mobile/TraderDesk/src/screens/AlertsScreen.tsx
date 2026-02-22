/**
 * AlertsScreen — shows threshold breach alerts from the server WebSocket.
 *
 * When the server detects a variable has moved beyond its configured delta
 * threshold, it broadcasts to the "alerts:<product_group>" Phoenix channel.
 * The socket service picks this up and dispatches to the Redux store.
 *
 * This screen shows the list of alerts with details:
 *   - Variable name + group
 *   - Current vs baseline value, delta, threshold
 *   - Timestamp
 *   - Whether the alert has been seen
 */

import React, {useEffect, useCallback} from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
} from 'react-native';
import {useDispatch, useSelector} from 'react-redux';
import {RootState, AppDispatch} from '../store';
import {markAllSeen, markSeen, clearAlerts} from '../store/alertsSlice';
import {ThresholdBreachEvent} from '../services/socket';

export default function AlertsScreen() {
  const dispatch = useDispatch<AppDispatch>();
  const {alerts, unseenCount, alertsEnabled} = useSelector((s: RootState) => s.alerts);

  useEffect(() => {
    // Mark all as seen when the user opens this screen
    if (unseenCount > 0) dispatch(markAllSeen());
  }, []);

  const renderAlert = useCallback(
    ({item}: {item: ThresholdBreachEvent & {id: string; seen: boolean}}) => (
      <AlertRow
        alert={item}
        onPress={() => dispatch(markSeen(item.id))}
      />
    ),
    [],
  );

  if (!alertsEnabled) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyTitle}>Alerts Disabled</Text>
        <Text style={styles.emptyText}>Enable threshold alerts in Settings.</Text>
      </View>
    );
  }

  return (
    <View style={styles.root}>
      {alerts.length === 0 ? (
        <View style={styles.center}>
          <Text style={styles.emptyTitle}>No Alerts</Text>
          <Text style={styles.emptyText}>
            Threshold breach alerts will appear here when variables move beyond their configured
            delta.
          </Text>
        </View>
      ) : (
        <>
          <View style={styles.headerRow}>
            <Text style={styles.headerCount}>
              {alerts.length} alert{alerts.length !== 1 ? 's' : ''}
            </Text>
            <TouchableOpacity onPress={() => dispatch(clearAlerts())}>
              <Text style={styles.clearBtn}>Clear All</Text>
            </TouchableOpacity>
          </View>
          <FlatList
            data={alerts}
            keyExtractor={item => item.id}
            renderItem={renderAlert}
            contentContainerStyle={styles.list}
          />
        </>
      )}
    </View>
  );
}

function AlertRow({
  alert,
  onPress,
}: {
  alert: ThresholdBreachEvent & {id: string; seen: boolean};
  onPress: () => void;
}) {
  const deltaSign = alert.delta >= 0 ? '+' : '';
  const isUp = alert.delta > 0;

  return (
    <TouchableOpacity
      style={[styles.alertCard, !alert.seen && styles.alertCardUnseen]}
      onPress={onPress}
      activeOpacity={0.7}>
      {/* Header row */}
      <View style={styles.alertHeader}>
        <View style={styles.alertTitleRow}>
          <Text style={styles.alertVariable}>{formatKey(alert.variable)}</Text>
          {!alert.seen && <View style={styles.unseenDot} />}
        </View>
        <Text style={styles.alertTs}>{formatTs(alert.timestamp)}</Text>
      </View>

      {/* Values */}
      <View style={styles.alertValues}>
        <ValueBox label="Current" value={alert.current} />
        <ValueBox label="Baseline" value={alert.baseline} />
        <View style={styles.deltaBox}>
          <Text style={styles.deltaLabel}>Delta</Text>
          <Text style={[styles.deltaValue, {color: isUp ? COLORS.red : COLORS.green}]}>
            {deltaSign}{alert.delta.toFixed(2)}
          </Text>
          <Text style={styles.deltaThreshold}>
            threshold: ±{alert.threshold}
          </Text>
        </View>
      </View>

      <Text style={styles.pgTag}>{alert.product_group.replace(/_/g, ' ')}</Text>
    </TouchableOpacity>
  );
}

function ValueBox({label, value}: {label: string; value: number}) {
  return (
    <View style={styles.valueBox}>
      <Text style={styles.valueLabel}>{label}</Text>
      <Text style={styles.valueNum}>{value.toFixed(2)}</Text>
    </View>
  );
}

function formatKey(key: string): string {
  return key.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}

function formatTs(ts: string): string {
  try {
    const d = new Date(ts);
    return d.toLocaleString();
  } catch {
    return ts;
  }
}

const COLORS = {
  bg: '#0D1117',
  card: '#161B22',
  border: '#30363D',
  text: '#E6EDF3',
  muted: '#8B949E',
  accent: '#58A6FF',
  green: '#3FB950',
  red: '#F85149',
  unseen: '#388BFD',
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: COLORS.bg},
  center: {
    flex: 1, justifyContent: 'center', alignItems: 'center',
    padding: 32, backgroundColor: COLORS.bg,
  },
  emptyTitle: {color: COLORS.text, fontSize: 18, fontWeight: '600', marginBottom: 8},
  emptyText: {color: COLORS.muted, fontSize: 14, textAlign: 'center'},
  headerRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingHorizontal: 16, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  headerCount: {color: COLORS.muted, fontSize: 13},
  clearBtn: {color: COLORS.red, fontSize: 13},
  list: {padding: 12, gap: 8},
  alertCard: {
    backgroundColor: COLORS.card, borderRadius: 10,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  alertCardUnseen: {borderColor: COLORS.unseen, borderLeftWidth: 3},
  alertHeader: {
    flexDirection: 'row', justifyContent: 'space-between',
    alignItems: 'flex-start', marginBottom: 10,
  },
  alertTitleRow: {flexDirection: 'row', alignItems: 'center', gap: 6},
  alertVariable: {color: COLORS.text, fontSize: 15, fontWeight: '600'},
  unseenDot: {width: 8, height: 8, borderRadius: 4, backgroundColor: COLORS.unseen},
  alertTs: {color: COLORS.muted, fontSize: 12},
  alertValues: {flexDirection: 'row', gap: 12, marginBottom: 8},
  valueBox: {flex: 1, alignItems: 'center'},
  valueLabel: {color: COLORS.muted, fontSize: 11},
  valueNum: {color: COLORS.text, fontSize: 16, fontWeight: '600'},
  deltaBox: {flex: 1, alignItems: 'center'},
  deltaLabel: {color: COLORS.muted, fontSize: 11},
  deltaValue: {fontSize: 18, fontWeight: '700'},
  deltaThreshold: {color: COLORS.muted, fontSize: 10, marginTop: 2},
  pgTag: {
    color: COLORS.muted, fontSize: 11, textTransform: 'uppercase',
    letterSpacing: 0.5, marginTop: 4,
  },
});
