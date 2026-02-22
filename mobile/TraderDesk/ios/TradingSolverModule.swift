// TradingSolverModule.swift
// React Native bridge to the Zig LP solver static library (libtrading_solver.a)
//
// The Zig library exposes a C ABI (see native/solver_mobile.zig).
// Swift calls it via @_silgen_name / UnsafePointer bridging through
// the solver_mobile.h C header.

import Foundation

// ── C struct mirrors (must match solver_mobile.zig extern structs) ────────────

struct CMobileSolveResult {
  var status:        Int32
  var profit:        Double
  var tons:          Double
  var cost:          Double
  var roi:           Double
  var n_routes:      Int32
  var route_tons:    (Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double)
  var route_profits: (Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double)
  var margins:       (Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double)
  var n_constraints: Int32
  var shadow_prices: (Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double,
                       Double, Double, Double, Double, Double, Double, Double, Double)
}

struct CMobileMonteCarloResult {
  var status:           Int32
  var n_scenarios:      UInt32
  var n_feasible:       UInt32
  var n_infeasible:     UInt32
  var mean:             Double
  var stddev:           Double
  var p5:               Double
  var p25:              Double
  var p50:              Double
  var p75:              Double
  var p95:              Double
  var min:              Double
  var max:              Double
  var n_sensitivity:    Int32
  var sensitivity_idx:  (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)
  var sensitivity_corr: (Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double)
}

// ── C function declarations ───────────────────────────────────────────────────
// These link to the exported symbols from libtrading_solver.a

@_silgen_name("trading_solve")
func trading_solve(
  _ model_descriptor: UnsafePointer<UInt8>,
  _ model_len: Int,
  _ variables: UnsafePointer<Double>,
  _ n_vars: Int,
  _ out: UnsafeMutablePointer<CMobileSolveResult>
) -> Int32

@_silgen_name("trading_monte_carlo")
func trading_monte_carlo(
  _ model_descriptor: UnsafePointer<UInt8>,
  _ model_len: Int,
  _ center: UnsafePointer<Double>,
  _ n_vars: Int,
  _ n_scenarios: UInt32,
  _ out: UnsafeMutablePointer<CMobileMonteCarloResult>
) -> Int32

@_silgen_name("trading_solver_version")
func trading_solver_version() -> UnsafePointer<CChar>

// ── React Native module ───────────────────────────────────────────────────────

@objc(TradingSolver)
class TradingSolverModule: NSObject {

  @objc static func requiresMainQueueSetup() -> Bool { false }

  // ── solve ──────────────────────────────────────────────────────────────────

  @objc func solve(
    _ descriptorBase64: String,
    variables variablesArray: [Double],
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let descriptorData = Data(base64Encoded: descriptorBase64) else {
        reject("INVALID_DESCRIPTOR", "Could not base64-decode model descriptor", nil)
        return
      }

      var result = CMobileSolveResult(
        status: 0, profit: 0, tons: 0, cost: 0, roi: 0,
        n_routes: 0,
        route_tons: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
        route_profits: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
        margins: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
        n_constraints: 0,
        shadow_prices: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
      )

      let status = descriptorData.withUnsafeBytes { descPtr in
        trading_solve(
          descPtr.bindMemory(to: UInt8.self).baseAddress!,
          descriptorData.count,
          variablesArray,
          variablesArray.count,
          &result
        )
      }

      let nRoutes = Int(result.n_routes)
      let nConstraints = Int(result.n_constraints)

      let routeTons = Self.tupleToArray16(result.route_tons, count: nRoutes)
      let routeProfits = Self.tupleToArray16(result.route_profits, count: nRoutes)
      let margins = Self.tupleToArray16(result.margins, count: nRoutes)
      let shadowPrices = Self.tupleToArray32(result.shadow_prices, count: nConstraints)

      resolve([
        "status": Int(status),
        "profit": result.profit,
        "tons": result.tons,
        "cost": result.cost,
        "roi": result.roi,
        "nRoutes": nRoutes,
        "routeTons": routeTons,
        "routeProfits": routeProfits,
        "margins": margins,
        "nConstraints": nConstraints,
        "shadowPrices": shadowPrices,
      ])
    }
  }

  // ── monteCarlo ─────────────────────────────────────────────────────────────

  @objc func monteCarlo(
    _ descriptorBase64: String,
    centerVariables: [Double],
    nScenarios: Int,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let descriptorData = Data(base64Encoded: descriptorBase64) else {
        reject("INVALID_DESCRIPTOR", "Could not base64-decode model descriptor", nil)
        return
      }

      var result = CMobileMonteCarloResult(
        status: 0, n_scenarios: 0, n_feasible: 0, n_infeasible: 0,
        mean: 0, stddev: 0, p5: 0, p25: 0, p50: 0, p75: 0, p95: 0,
        min: 0, max: 0, n_sensitivity: 0,
        sensitivity_idx:  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
        sensitivity_corr: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
      )

      let status = descriptorData.withUnsafeBytes { descPtr in
        trading_monte_carlo(
          descPtr.bindMemory(to: UInt8.self).baseAddress!,
          descriptorData.count,
          centerVariables,
          centerVariables.count,
          UInt32(nScenarios),
          &result
        )
      }

      let nSens = Int(result.n_sensitivity)
      let sensIdx = Self.tupleToArray64Int(result.sensitivity_idx, count: nSens)
      let sensCorr = Self.tupleToArray64(result.sensitivity_corr, count: nSens)

      resolve([
        "status": Int(status),
        "nScenarios": Int(result.n_scenarios),
        "nFeasible": Int(result.n_feasible),
        "nInfeasible": Int(result.n_infeasible),
        "mean": result.mean,
        "stddev": result.stddev,
        "p5": result.p5,
        "p25": result.p25,
        "p50": result.p50,
        "p75": result.p75,
        "p95": result.p95,
        "min": result.min,
        "max": result.max,
        "sensitivityIdx": sensIdx,
        "sensitivityCorr": sensCorr,
      ])
    }
  }

  // ── getVersion ─────────────────────────────────────────────────────────────

  @objc func getVersion(
    _ resolve: @escaping RCTPromiseResolveBlock,
    reject _: @escaping RCTPromiseRejectBlock
  ) {
    let ptr = trading_solver_version()
    resolve(String(cString: ptr))
  }

  // ── Array helpers (Swift tuple → [Double/Int32]) ──────────────────────────

  private static func tupleToArray16(
    _ t: (Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double),
    count: Int
  ) -> [Double] {
    let arr = [t.0,t.1,t.2,t.3,t.4,t.5,t.6,t.7,t.8,t.9,t.10,t.11,t.12,t.13,t.14,t.15]
    return Array(arr.prefix(count))
  }

  private static func tupleToArray32(
    _ t: (Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double),
    count: Int
  ) -> [Double] {
    let arr = [t.0,t.1,t.2,t.3,t.4,t.5,t.6,t.7,t.8,t.9,t.10,t.11,t.12,t.13,t.14,t.15,
               t.16,t.17,t.18,t.19,t.20,t.21,t.22,t.23,t.24,t.25,t.26,t.27,t.28,t.29,t.30,t.31]
    return Array(arr.prefix(count))
  }

  private static func tupleToArray64(
    _ t: (Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double,
          Double, Double, Double, Double, Double, Double, Double, Double),
    count: Int
  ) -> [Double] {
    var arr: [Double] = []
    let mirror = Mirror(reflecting: t)
    for child in mirror.children { arr.append(child.value as! Double) } // swiftlint:disable:this force_cast
    return Array(arr.prefix(count))
  }

  private static func tupleToArray64Int(
    _ t: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
          Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32),
    count: Int
  ) -> [Int32] {
    var arr: [Int32] = []
    let mirror = Mirror(reflecting: t)
    for child in mirror.children { arr.append(child.value as! Int32) } // swiftlint:disable:this force_cast
    return Array(arr.prefix(count))
  }
}
