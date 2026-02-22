/**
 * SolveResultScreen — shows the output of a device-side solve.
 *
 * Single solve output:
 *   - Signal badge (Optimal / Infeasible / Error)
 *   - Key metrics: Profit, Tons, Cost, ROI
 *   - Per-route breakdown: tons, profit, margin
 *   - Shadow prices (binding constraint values)
 *   - "Save" button — saves locally + queues server sync
 *
 * Monte Carlo output:
 *   - Signal badge (Strong Go / Go / Cautious / Weak / No Go)
 *   - Distribution: P5, P25, P50, P75, P95, Mean, StdDev
 *   - Feasibility rate
 *   - Top variable sensitivities (Pearson correlations)
 */

import React, {useCallback, useState} from 'react';
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from 'react-native';
import {useDispatch, useSelector} from 'react-redux';
import {RootState, AppDispatch} from '../store';
import {saveToServer, clearResult} from '../store/solveSlice';
import {SaveSolveRequest} from '../services/api';
import {useNavigation} from '@react-navigation/native';

const SIGNAL_COLORS: Record<string, string> = {
  strong_go: '#3FB950',
  go: '#58A6FF',
  cautious: '#D29922',
  weak: '#F0883E',
  no_go: '#F85149',
  optimal: '#3FB950',
  infeasible: '#F85149',
  error: '#6E7681',
  bad_input: '#6E7681',
};

const SIGNAL_LABELS: Record<string, string> = {
  strong_go: 'STRONG GO',
  go: 'GO',
  cautious: 'CAUTIOUS',
  weak: 'WEAK',
  no_go: 'NO-GO',
  optimal: 'OPTIMAL',
  infeasible: 'INFEASIBLE',
  error: 'ERROR',
  bad_input: 'BAD INPUT',
};

export default function SolveResultScreen() {
  const dispatch = useDispatch<AppDispatch>();
  const navigation = useNavigation<any>();
  const [saving, setSaving] = useState(false);

  const {result, mcResult, lastSolvedAt, savedToServer, saveQueue} = useSelector(
    (s: RootState) => s.solve,
  );
  const {payload: modelPayload, selectedProductGroup, selectedObjective} = useSelector(
    (s: RootState) => s.model,
  );
  const effectiveVars = useSelector((s: RootState) => {
    const base = s.model.payload?.variables ?? {};
    return {...base, ...s.model.variableOverrides};
  });
  const {traderId, deviceId} = useSelector((s: RootState) => s.settings);

  const onSave = useCallback(async () => {
    if (!result && !mcResult) return;
    setSaving(true);

    const request: SaveSolveRequest = {
      product_group: selectedProductGroup,
      variables: effectiveVars,
      result: result
        ? {
            status: result.status === 'optimal' ? 'optimal' : result.status === 'infeasible' ? 'infeasible' : 'error',
            profit: result.profit,
            tons: result.tons,
            cost: result.cost,
            roi: result.roi,
            route_tons: result.routeTons,
            route_profits: result.routeProfits,
            margins: result.margins,
            shadow_prices: result.shadowPrices,
          }
        : {
            status: 'optimal',
            profit: mcResult!.mean,
            tons: 0,
            cost: 0,
            roi: 0,
            route_tons: [],
            route_profits: [],
            margins: [],
            shadow_prices: [],
          },
      mode: mcResult ? 'monte_carlo' : 'solve',
      trader_id: traderId,
      solved_at: lastSolvedAt ?? new Date().toISOString(),
      device_id: deviceId,
    };

    await dispatch(saveToServer(request));
    setSaving(false);

    Alert.alert(
      'Saved',
      savedToServer
        ? 'Solve saved to server.'
        : 'Could not reach server — saved locally, will sync when connected.',
    );
  }, [result, mcResult, selectedProductGroup, effectiveVars, traderId, deviceId, lastSolvedAt]);

  const onDiscard = useCallback(() => {
    dispatch(clearResult());
    navigation.goBack();
  }, []);

  if (!result && !mcResult) {
    return (
      <View style={styles.center}>
        <Text style={styles.muted}>No solve result to display.</Text>
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <ScrollView style={styles.scroll}>
        {result ? (
          <SingleSolveView result={result} modelPayload={modelPayload} />
        ) : (
          <MonteCarloView mc={mcResult!} modelPayload={modelPayload} />
        )}

        {saveQueue.length > 0 && (
          <View style={styles.queueBanner}>
            <Text style={styles.queueText}>
              {saveQueue.length} solve{saveQueue.length > 1 ? 's' : ''} pending sync to server
            </Text>
          </View>
        )}

        <View style={{height: 32}} />
      </ScrollView>

      <View style={styles.actionBar}>
        <TouchableOpacity style={[styles.btn, styles.discardBtn]} onPress={onDiscard}>
          <Text style={styles.btnText}>Discard</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.btn, styles.saveBtn, (saving || savedToServer) && styles.btnDisabled]}
          onPress={onSave}
          disabled={saving || savedToServer}>
          {saving ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text style={styles.btnText}>{savedToServer ? 'Saved ✓' : 'Save'}</Text>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}

// ── Single solve result ─────────────────────────────────────────────────────────

function SingleSolveView({result, modelPayload}: {result: any; modelPayload: any}) {
  const signal = result.status;
  const color = SIGNAL_COLORS[signal] ?? '#6E7681';
  const routes = modelPayload?.routes ?? [];

  return (
    <>
      {/* Signal badge */}
      <View style={[styles.signalCard, {borderColor: color}]}>
        <Text style={[styles.signalLabel, {color}]}>{SIGNAL_LABELS[signal] ?? signal.toUpperCase()}</Text>
        <Text style={styles.signalTs}>Device solve</Text>
      </View>

      {/* Key metrics */}
      <View style={styles.metricsGrid}>
        <MetricCard label="Profit" value={`$${fmt(result.profit)}`} color={COLORS.green} />
        <MetricCard label="Tons" value={fmt(result.tons)} color={COLORS.text} />
        <MetricCard label="Cost" value={`$${fmt(result.cost)}`} color={COLORS.muted} />
        <MetricCard label="ROI" value={`${result.roi.toFixed(1)}%`} color={COLORS.accent} />
      </View>

      {/* Route breakdown */}
      {result.nRoutes > 0 && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Route Breakdown</Text>
          {result.routeTons.slice(0, result.nRoutes).map((tons: number, i: number) => {
            if (tons < 0.5) return null;
            const route = routes[i];
            return (
              <View key={i} style={styles.routeRow}>
                <Text style={styles.routeLabel}>
                  {route?.label ?? `Route ${i + 1}`}
                </Text>
                <View style={styles.routeMetrics}>
                  <Text style={styles.routeMetric}>{fmt(tons)} t</Text>
                  <Text style={[styles.routeMetric, {color: COLORS.green}]}>
                    ${fmt(result.routeProfits[i])}
                  </Text>
                  <Text style={styles.routeMetric}>
                    ${result.margins[i].toFixed(1)}/t
                  </Text>
                </View>
              </View>
            );
          })}
        </View>
      )}

      {/* Shadow prices */}
      {result.nConstraints > 0 && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Shadow Prices (Binding Constraints)</Text>
          {result.shadowPrices.slice(0, result.nConstraints).map((sp: number, i: number) => {
            if (Math.abs(sp) < 0.001) return null;
            const con = modelPayload?.constraints?.[i];
            return (
              <View key={i} style={styles.shadowRow}>
                <Text style={styles.shadowLabel}>{con?.label ?? `Constraint ${i + 1}`}</Text>
                <Text style={styles.shadowVal}>${sp.toFixed(2)}/t</Text>
              </View>
            );
          })}
        </View>
      )}
    </>
  );
}

// ── Monte Carlo result ─────────────────────────────────────────────────────────

function MonteCarloView({mc, modelPayload}: {mc: any; modelPayload: any}) {
  const signal = mc.signal;
  const color = SIGNAL_COLORS[signal] ?? '#6E7681';
  const feasRate = mc.nScenarios > 0 ? (mc.nFeasible / mc.nScenarios * 100).toFixed(0) : '0';
  const varMeta = modelPayload?.metadata ?? [];

  return (
    <>
      {/* Signal */}
      <View style={[styles.signalCard, {borderColor: color}]}>
        <Text style={[styles.signalLabel, {color}]}>{SIGNAL_LABELS[signal] ?? signal.toUpperCase()}</Text>
        <Text style={styles.signalTs}>
          {mc.nScenarios.toLocaleString()} scenarios · {feasRate}% feasible
        </Text>
      </View>

      {/* Distribution */}
      <View style={styles.metricsGrid}>
        <MetricCard label="P50 (Median)" value={`$${fmt(mc.p50)}`} color={color} />
        <MetricCard label="Mean" value={`$${fmt(mc.mean)}`} color={COLORS.text} />
        <MetricCard label="P5 (Tail Risk)" value={`$${fmt(mc.p5)}`} color={COLORS.red} />
        <MetricCard label="P95 (Upside)" value={`$${fmt(mc.p95)}`} color={COLORS.green} />
      </View>

      {/* Percentile bar */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Profit Distribution</Text>
        <View style={styles.distRow}>
          <DistLabel label="P5" value={mc.p5} />
          <DistLabel label="P25" value={mc.p25} />
          <DistLabel label="P50" value={mc.p50} />
          <DistLabel label="P75" value={mc.p75} />
          <DistLabel label="P95" value={mc.p95} />
        </View>
        <Text style={styles.distRange}>
          Range: ${fmt(mc.min)} — ${fmt(mc.max)} · StdDev: ${fmt(mc.stddev)}
        </Text>
      </View>

      {/* Sensitivities */}
      {mc.sensitivityIdx?.length > 0 && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Top Sensitivities (|Pearson|)</Text>
          {mc.sensitivityIdx.slice(0, 6).map((idx: number, i: number) => {
            const corr = mc.sensitivityCorr[i];
            const meta = varMeta[idx];
            if (!meta || Math.abs(corr) < 0.01) return null;
            const pct = Math.abs(corr * 100).toFixed(0);
            const isPos = corr > 0;
            return (
              <View key={i} style={styles.sensRow}>
                <Text style={styles.sensLabel}>{meta.label}</Text>
                <View style={[styles.sensBar, {width: `${pct}%` as any, backgroundColor: isPos ? COLORS.green : COLORS.red}]} />
                <Text style={[styles.sensCorr, {color: isPos ? COLORS.green : COLORS.red}]}>
                  {isPos ? '+' : ''}{corr.toFixed(2)}
                </Text>
              </View>
            );
          })}
        </View>
      )}
    </>
  );
}

// ── Sub-components ─────────────────────────────────────────────────────────────

function MetricCard({label, value, color}: {label: string; value: string; color: string}) {
  return (
    <View style={styles.metricCard}>
      <Text style={[styles.metricValue, {color}]}>{value}</Text>
      <Text style={styles.metricLabel}>{label}</Text>
    </View>
  );
}

function DistLabel({label, value}: {label: string; value: number}) {
  return (
    <View style={styles.distLabel}>
      <Text style={styles.distLabelText}>{label}</Text>
      <Text style={styles.distLabelValue}>${fmt(value)}</Text>
    </View>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function fmt(n: number): string {
  if (n === undefined || n === null) return '—';
  if (Math.abs(n) >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (Math.abs(n) >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return n.toFixed(0);
}

const COLORS = {
  bg: '#0D1117',
  card: '#161B22',
  border: '#30363D',
  text: '#E6EDF3',
  muted: '#8B949E',
  accent: '#58A6FF',
  green: '#3FB950',
  yellow: '#D29922',
  red: '#F85149',
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: COLORS.bg},
  center: {flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: COLORS.bg},
  scroll: {flex: 1},
  muted: {color: COLORS.muted, fontSize: 14},
  signalCard: {
    margin: 12, padding: 16, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 2,
    alignItems: 'center',
  },
  signalLabel: {fontSize: 28, fontWeight: '800', letterSpacing: 1},
  signalTs: {color: COLORS.muted, fontSize: 13, marginTop: 4},
  metricsGrid: {
    flexDirection: 'row', flexWrap: 'wrap',
    paddingHorizontal: 8, gap: 8,
  },
  metricCard: {
    flex: 1, minWidth: '44%', backgroundColor: COLORS.card,
    borderRadius: 10, padding: 14, borderWidth: 1, borderColor: COLORS.border,
  },
  metricValue: {fontSize: 22, fontWeight: '700'},
  metricLabel: {color: COLORS.muted, fontSize: 12, marginTop: 4},
  section: {
    margin: 12, padding: 14, backgroundColor: COLORS.card,
    borderRadius: 10, borderWidth: 1, borderColor: COLORS.border,
  },
  sectionTitle: {color: COLORS.text, fontWeight: '600', fontSize: 14, marginBottom: 10},
  routeRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    alignItems: 'center', paddingVertical: 6,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  routeLabel: {color: COLORS.text, fontSize: 13, flex: 1},
  routeMetrics: {flexDirection: 'row', gap: 12},
  routeMetric: {color: COLORS.muted, fontSize: 13, minWidth: 60, textAlign: 'right'},
  shadowRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    paddingVertical: 5,
  },
  shadowLabel: {color: COLORS.text, fontSize: 13},
  shadowVal: {color: COLORS.accent, fontSize: 13, fontWeight: '600'},
  distRow: {flexDirection: 'row', justifyContent: 'space-between', marginBottom: 8},
  distLabel: {alignItems: 'center'},
  distLabelText: {color: COLORS.muted, fontSize: 11},
  distLabelValue: {color: COLORS.text, fontSize: 12, fontWeight: '600'},
  distRange: {color: COLORS.muted, fontSize: 12},
  sensRow: {
    flexDirection: 'row', alignItems: 'center',
    gap: 8, marginBottom: 6,
  },
  sensLabel: {color: COLORS.text, fontSize: 12, width: 120},
  sensBar: {height: 6, borderRadius: 3, minWidth: 2},
  sensCorr: {fontSize: 12, fontWeight: '600', width: 40, textAlign: 'right'},
  queueBanner: {
    margin: 12, padding: 12, backgroundColor: '#2D1B00',
    borderRadius: 8, borderWidth: 1, borderColor: '#D29922',
  },
  queueText: {color: '#D29922', fontSize: 13, textAlign: 'center'},
  actionBar: {
    flexDirection: 'row', padding: 12, gap: 10,
    borderTopWidth: 1, borderTopColor: COLORS.border, backgroundColor: COLORS.card,
  },
  btn: {flex: 1, paddingVertical: 14, borderRadius: 10, alignItems: 'center'},
  discardBtn: {backgroundColor: '#21262D', borderWidth: 1, borderColor: COLORS.border},
  saveBtn: {backgroundColor: '#1F6FEB'},
  btnDisabled: {opacity: 0.5},
  btnText: {color: '#fff', fontWeight: '700', fontSize: 15},
});
