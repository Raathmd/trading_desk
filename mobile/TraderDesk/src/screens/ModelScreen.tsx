/**
 * ModelScreen — displays the current model received from the server.
 *
 * Shows:
 *   - Product group + objective selector
 *   - All variables grouped by category (Environment / Operations / Commercial)
 *   - Each variable's current value, unit, source, and allowed range
 *   - Trader can adjust values (overrides) before solving
 *   - "Solve" button runs the Zig solver on-device
 *   - "Monte Carlo" button runs the stochastic analysis
 *   - Connection status indicator
 */

import React, {useEffect, useCallback} from 'react';
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
  StyleSheet,
  Switch,
  TextInput,
  Alert,
} from 'react-native';
import {useDispatch, useSelector} from 'react-redux';
import {RootState, AppDispatch} from '../store';
import {
  loadModel,
  setVariableOverride,
  resetOverrides,
  setObjective,
  selectEffectiveVariables,
  selectVariablesArray,
} from '../store/modelSlice';
import {runSolve, runMonteCarlo} from '../store/solveSlice';
import {VariableMeta, ObjectiveMode} from '../services/api';
import {useNavigation} from '@react-navigation/native';

const OBJECTIVES: {value: ObjectiveMode; label: string}[] = [
  {value: 'max_profit', label: 'Max Profit'},
  {value: 'min_cost', label: 'Min Cost'},
  {value: 'max_roi', label: 'Max ROI'},
  {value: 'cvar_adjusted', label: 'CVaR Adjusted'},
  {value: 'min_risk', label: 'Min Risk'},
];

const GROUP_LABELS: Record<string, string> = {
  environment: 'Environment',
  operations: 'Operations',
  commercial: 'Commercial',
};

export default function ModelScreen() {
  const dispatch = useDispatch<AppDispatch>();
  const navigation = useNavigation<any>();

  const {payload, loading, error, variableOverrides, selectedObjective, selectedProductGroup} =
    useSelector((s: RootState) => s.model);
  const {solving} = useSelector((s: RootState) => s.solve);
  const effectiveVars = useSelector(selectEffectiveVariables);
  const variablesArray = useSelector(selectVariablesArray);

  useEffect(() => {
    dispatch(loadModel({productGroup: selectedProductGroup, objective: selectedObjective}));
  }, [selectedProductGroup, selectedObjective]);

  const onRefresh = useCallback(() => {
    dispatch(loadModel({productGroup: selectedProductGroup, objective: selectedObjective}));
  }, [selectedProductGroup, selectedObjective]);

  const onSolve = useCallback(async () => {
    if (!payload) return;
    const result = await dispatch(
      runSolve({descriptor: payload.descriptor, variables: variablesArray}),
    );
    if (runSolve.fulfilled.match(result)) {
      navigation.navigate('SolveResult');
    }
  }, [payload, variablesArray]);

  const onMonteCarlo = useCallback(async () => {
    if (!payload) return;
    const result = await dispatch(
      runMonteCarlo({descriptor: payload.descriptor, variables: variablesArray, nScenarios: 500}),
    );
    if (runMonteCarlo.fulfilled.match(result)) {
      navigation.navigate('SolveResult');
    }
  }, [payload, variablesArray]);

  const onResetOverrides = useCallback(() => {
    Alert.alert('Reset Variables', 'Reset all overrides to server values?', [
      {text: 'Cancel', style: 'cancel'},
      {text: 'Reset', style: 'destructive', onPress: () => dispatch(resetOverrides())},
    ]);
  }, []);

  if (loading && !payload) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color={COLORS.accent} />
        <Text style={styles.loadingText}>Loading model from server…</Text>
      </View>
    );
  }

  if (error && !payload) {
    return (
      <View style={styles.center}>
        <Text style={styles.errorTitle}>Could not load model</Text>
        <Text style={styles.errorText}>{error}</Text>
        <TouchableOpacity style={styles.btn} onPress={onRefresh}>
          <Text style={styles.btnText}>Retry</Text>
        </TouchableOpacity>
      </View>
    );
  }

  const groups = groupByCategory(payload?.metadata ?? []);
  const hasOverrides = Object.keys(variableOverrides).length > 0;

  return (
    <View style={styles.root}>
      {/* ── Header ─────────────────────────────────────────────── */}
      <View style={styles.header}>
        <View>
          <Text style={styles.pgLabel}>
            {payload?.product_group.replace(/_/g, ' ').toUpperCase() ?? '—'}
          </Text>
          <Text style={styles.tsLabel}>
            {payload ? `Updated ${formatTs(payload.timestamp)}` : ''}
          </Text>
        </View>
        {hasOverrides && (
          <TouchableOpacity onPress={onResetOverrides} style={styles.resetBtn}>
            <Text style={styles.resetBtnText}>Reset</Text>
          </TouchableOpacity>
        )}
      </View>

      {/* ── Objective selector ──────────────────────────────────── */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.objBar}
        contentContainerStyle={styles.objBarContent}>
        {OBJECTIVES.map(obj => (
          <TouchableOpacity
            key={obj.value}
            style={[styles.objChip, selectedObjective === obj.value && styles.objChipActive]}
            onPress={() => dispatch(setObjective(obj.value))}>
            <Text
              style={[
                styles.objChipText,
                selectedObjective === obj.value && styles.objChipTextActive,
              ]}>
              {obj.label}
            </Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      {/* ── Variables ───────────────────────────────────────────── */}
      <ScrollView
        style={styles.scroll}
        refreshControl={
          <RefreshControl refreshing={loading} onRefresh={onRefresh} tintColor={COLORS.accent} />
        }>

        {/* Model summary: routes + constraints */}
        {payload && (
          <View style={styles.summaryCard}>
            <Text style={styles.summaryTitle}>Model Structure</Text>
            <View style={styles.summaryRow}>
              <SummaryBadge label={`${payload.routes.length} Routes`} />
              <SummaryBadge label={`${payload.constraints.length} Constraints`} />
              <SummaryBadge label={`${payload.variable_count} Variables`} />
            </View>
            <Text style={styles.summaryRoutesLabel}>Routes:</Text>
            {payload.routes.map(r => (
              <Text key={r.key} style={styles.summaryRoute}>
                {r.label}
                {r.origin && r.destination ? ` (${r.origin} → ${r.destination})` : ''}
                {` • ${r.unit_capacity.toLocaleString()} t capacity`}
              </Text>
            ))}
          </View>
        )}

        {/* Variable groups */}
        {Object.entries(groups).map(([group, metas]) => (
          <View key={group} style={styles.group}>
            <Text style={styles.groupLabel}>{GROUP_LABELS[group] ?? group}</Text>
            {metas.map(meta => (
              <VariableRow
                key={meta.key}
                meta={meta}
                value={effectiveVars[meta.key]}
                isOverridden={meta.key in variableOverrides}
                onChange={val => dispatch(setVariableOverride({key: meta.key, value: val}))}
              />
            ))}
          </View>
        ))}

        <View style={{height: 32}} />
      </ScrollView>

      {/* ── Action buttons ──────────────────────────────────────── */}
      <View style={styles.actionBar}>
        <TouchableOpacity
          style={[styles.actionBtn, styles.solveBtn, solving && styles.btnDisabled]}
          onPress={onSolve}
          disabled={solving || !payload}>
          {solving ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text style={styles.actionBtnText}>Solve</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.actionBtn, styles.mcBtn, solving && styles.btnDisabled]}
          onPress={onMonteCarlo}
          disabled={solving || !payload}>
          <Text style={styles.actionBtnText}>Monte Carlo</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

// ── Sub-components ─────────────────────────────────────────────────────────────

function VariableRow({
  meta,
  value,
  isOverridden,
  onChange,
}: {
  meta: VariableMeta;
  value: number | boolean | undefined;
  isOverridden: boolean;
  onChange: (val: number | boolean) => void;
}) {
  const displayVal = value ?? meta.min;

  return (
    <View style={[styles.varRow, isOverridden && styles.varRowOverridden]}>
      <View style={styles.varInfo}>
        <Text style={styles.varLabel}>
          {meta.label}
          {isOverridden && <Text style={styles.overrideBadge}> ●</Text>}
        </Text>
        <Text style={styles.varSource}>{meta.source.toUpperCase()}</Text>
      </View>

      {meta.type === 'boolean' ? (
        <View style={styles.varControl}>
          <Switch
            value={!!displayVal}
            onValueChange={onChange}
            trackColor={{false: COLORS.muted, true: COLORS.accent}}
          />
        </View>
      ) : (
        <View style={styles.varControl}>
          <TextInput
            style={styles.varInput}
            value={String(displayVal)}
            onChangeText={t => {
              const n = parseFloat(t);
              if (!isNaN(n)) onChange(n);
            }}
            keyboardType="numeric"
            selectTextOnFocus
          />
          <Text style={styles.varUnit}>{meta.unit}</Text>
        </View>
      )}

      <Text style={styles.varRange}>
        {meta.type !== 'boolean' ? `${meta.min}–${meta.max}` : ''}
      </Text>
    </View>
  );
}

function SummaryBadge({label}: {label: string}) {
  return (
    <View style={styles.badge}>
      <Text style={styles.badgeText}>{label}</Text>
    </View>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function groupByCategory(metadata: VariableMeta[]): Record<string, VariableMeta[]> {
  return metadata.reduce((acc, m) => {
    const g = m.group || 'other';
    acc[g] = [...(acc[g] ?? []), m];
    return acc;
  }, {} as Record<string, VariableMeta[]>);
}

function formatTs(ts: string): string {
  try {
    return new Date(ts).toLocaleTimeString();
  } catch {
    return ts;
  }
}

// ── Colors ─────────────────────────────────────────────────────────────────────

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
  override: '#388BFD20',
};

// ── Styles ─────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: COLORS.bg},
  center: {flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: COLORS.bg, padding: 24},
  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingHorizontal: 16, paddingTop: 16, paddingBottom: 8,
  },
  pgLabel: {color: COLORS.text, fontSize: 16, fontWeight: '700', letterSpacing: 0.5},
  tsLabel: {color: COLORS.muted, fontSize: 12, marginTop: 2},
  resetBtn: {paddingHorizontal: 12, paddingVertical: 6, borderRadius: 6, borderWidth: 1, borderColor: COLORS.border},
  resetBtnText: {color: COLORS.muted, fontSize: 13},
  objBar: {maxHeight: 44},
  objBarContent: {paddingHorizontal: 16, gap: 8, alignItems: 'center'},
  objChip: {
    paddingHorizontal: 14, paddingVertical: 6, borderRadius: 20,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  objChipActive: {backgroundColor: COLORS.accent, borderColor: COLORS.accent},
  objChipText: {color: COLORS.muted, fontSize: 13},
  objChipTextActive: {color: '#fff', fontWeight: '600'},
  scroll: {flex: 1},
  summaryCard: {
    margin: 12, padding: 14, backgroundColor: COLORS.card,
    borderRadius: 10, borderWidth: 1, borderColor: COLORS.border,
  },
  summaryTitle: {color: COLORS.text, fontWeight: '600', fontSize: 14, marginBottom: 8},
  summaryRow: {flexDirection: 'row', gap: 8, marginBottom: 10, flexWrap: 'wrap'},
  summaryRoutesLabel: {color: COLORS.muted, fontSize: 12, marginBottom: 4},
  summaryRoute: {color: COLORS.text, fontSize: 12, marginBottom: 2},
  badge: {
    paddingHorizontal: 10, paddingVertical: 4,
    backgroundColor: '#1C2128', borderRadius: 12, borderWidth: 1, borderColor: COLORS.border,
  },
  badgeText: {color: COLORS.muted, fontSize: 12},
  group: {marginHorizontal: 12, marginBottom: 8},
  groupLabel: {
    color: COLORS.muted, fontSize: 11, fontWeight: '700',
    letterSpacing: 1, marginBottom: 6, marginLeft: 2, textTransform: 'uppercase',
  },
  varRow: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: 8, padding: 10,
    marginBottom: 4, borderWidth: 1, borderColor: COLORS.border,
  },
  varRowOverridden: {borderColor: COLORS.accent + '60', backgroundColor: COLORS.override},
  varInfo: {flex: 1},
  varLabel: {color: COLORS.text, fontSize: 13, fontWeight: '500'},
  varSource: {color: COLORS.muted, fontSize: 10, marginTop: 1},
  overrideBadge: {color: COLORS.accent, fontSize: 10},
  varControl: {flexDirection: 'row', alignItems: 'center', gap: 4},
  varInput: {
    color: COLORS.text, fontSize: 13, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: 6, paddingHorizontal: 8, paddingVertical: 4,
    minWidth: 70, textAlign: 'right', backgroundColor: COLORS.bg,
  },
  varUnit: {color: COLORS.muted, fontSize: 12, width: 36},
  varRange: {color: COLORS.muted, fontSize: 10, width: 60, textAlign: 'right'},
  actionBar: {
    flexDirection: 'row', padding: 12, gap: 10,
    borderTopWidth: 1, borderTopColor: COLORS.border, backgroundColor: COLORS.card,
  },
  actionBtn: {flex: 1, paddingVertical: 14, borderRadius: 10, alignItems: 'center'},
  solveBtn: {backgroundColor: COLORS.green},
  mcBtn: {backgroundColor: '#1F6FEB'},
  btnDisabled: {opacity: 0.5},
  actionBtnText: {color: '#fff', fontWeight: '700', fontSize: 15},
  loadingText: {color: COLORS.muted, marginTop: 12, fontSize: 14},
  errorTitle: {color: COLORS.red, fontSize: 16, fontWeight: '700', marginBottom: 8},
  errorText: {color: COLORS.muted, fontSize: 14, textAlign: 'center', marginBottom: 16},
  btn: {backgroundColor: COLORS.accent, paddingHorizontal: 24, paddingVertical: 12, borderRadius: 8},
  btnText: {color: '#fff', fontWeight: '600'},
});
