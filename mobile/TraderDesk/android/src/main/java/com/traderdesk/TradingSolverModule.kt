package com.traderdesk

import android.util.Base64
import com.facebook.react.bridge.*
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.DoubleBuffer

/**
 * TradingSolverModule — React Native bridge to the Zig LP solver (.so)
 *
 * The native library (libtrading_solver.so) is loaded via System.loadLibrary.
 * JNI declarations delegate to the C-ABI functions exported by solver_mobile.zig.
 *
 * Build:
 *   The .so files for each ABI are placed in:
 *   android/src/main/jniLibs/<abi>/libtrading_solver.so
 *
 *   Supported ABIs: arm64-v8a, armeabi-v7a, x86_64
 */
class TradingSolverModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getName() = "TradingSolver"

    companion object {
        init {
            System.loadLibrary("trading_solver")
        }

        // ── JNI declarations ────────────────────────────────────────────────
        // These match the C signatures in solver_mobile.zig

        @JvmStatic
        external fun nativeSolve(
            modelDescriptor: ByteArray,
            modelLen: Int,
            variables: DoubleArray,
            nVars: Int,
            outStatus: IntArray,        // [0] = status
            outScalars: DoubleArray,    // [profit, tons, cost, roi]
            outNRoutes: IntArray,       // [0] = n_routes
            outRouteTons: DoubleArray,  // [16]
            outRouteProfits: DoubleArray,
            outMargins: DoubleArray,
            outNConstraints: IntArray,  // [0] = n_constraints
            outShadowPrices: DoubleArray // [32]
        ): Int

        @JvmStatic
        external fun nativeMonteCarlo(
            modelDescriptor: ByteArray,
            modelLen: Int,
            center: DoubleArray,
            nVars: Int,
            nScenarios: Int,
            outStatus: IntArray,
            outCounts: IntArray,        // [n_scenarios, n_feasible, n_infeasible]
            outStats: DoubleArray,      // [mean, stddev, p5, p25, p50, p75, p95, min, max]
            outNSens: IntArray,         // [0] = n_sensitivity
            outSensIdx: IntArray,       // [64]
            outSensCorr: DoubleArray    // [64]
        ): Int

        @JvmStatic
        external fun nativeGetVersion(): String
    }

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    // ── solve ──────────────────────────────────────────────────────────────────

    @ReactMethod
    fun solve(
        descriptorBase64: String,
        variablesArray: ReadableArray,
        promise: Promise
    ) {
        scope.launch {
            try {
                val descriptor = Base64.decode(descriptorBase64, Base64.DEFAULT)
                val variables = variablesArray.toDoubleArray()

                val outStatus = IntArray(1)
                val outScalars = DoubleArray(4)
                val outNRoutes = IntArray(1)
                val outRouteTons = DoubleArray(16)
                val outRouteProfits = DoubleArray(16)
                val outMargins = DoubleArray(16)
                val outNConstraints = IntArray(1)
                val outShadowPrices = DoubleArray(32)

                nativeSolve(
                    descriptor, descriptor.size,
                    variables, variables.size,
                    outStatus, outScalars,
                    outNRoutes, outRouteTons, outRouteProfits, outMargins,
                    outNConstraints, outShadowPrices
                )

                val nRoutes = outNRoutes[0]
                val nConstraints = outNConstraints[0]

                val result = Arguments.createMap().apply {
                    putInt("status", outStatus[0])
                    putDouble("profit", outScalars[0])
                    putDouble("tons", outScalars[1])
                    putDouble("cost", outScalars[2])
                    putDouble("roi", outScalars[3])
                    putInt("nRoutes", nRoutes)
                    putArray("routeTons", outRouteTons.take(nRoutes).toReadableArray())
                    putArray("routeProfits", outRouteProfits.take(nRoutes).toReadableArray())
                    putArray("margins", outMargins.take(nRoutes).toReadableArray())
                    putInt("nConstraints", nConstraints)
                    putArray("shadowPrices", outShadowPrices.take(nConstraints).toReadableArray())
                }

                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("SOLVER_ERROR", e.message, e)
            }
        }
    }

    // ── monteCarlo ─────────────────────────────────────────────────────────────

    @ReactMethod
    fun monteCarlo(
        descriptorBase64: String,
        centerArray: ReadableArray,
        nScenarios: Int,
        promise: Promise
    ) {
        scope.launch {
            try {
                val descriptor = Base64.decode(descriptorBase64, Base64.DEFAULT)
                val center = centerArray.toDoubleArray()

                val outStatus = IntArray(1)
                val outCounts = IntArray(3)
                val outStats = DoubleArray(9)
                val outNSens = IntArray(1)
                val outSensIdx = IntArray(64)
                val outSensCorr = DoubleArray(64)

                nativeMonteCarlo(
                    descriptor, descriptor.size,
                    center, center.size,
                    nScenarios,
                    outStatus, outCounts, outStats,
                    outNSens, outSensIdx, outSensCorr
                )

                val nSens = outNSens[0]

                val result = Arguments.createMap().apply {
                    putInt("status", outStatus[0])
                    putInt("nScenarios", outCounts[0])
                    putInt("nFeasible", outCounts[1])
                    putInt("nInfeasible", outCounts[2])
                    putDouble("mean", outStats[0])
                    putDouble("stddev", outStats[1])
                    putDouble("p5", outStats[2])
                    putDouble("p25", outStats[3])
                    putDouble("p50", outStats[4])
                    putDouble("p75", outStats[5])
                    putDouble("p95", outStats[6])
                    putDouble("min", outStats[7])
                    putDouble("max", outStats[8])
                    putArray("sensitivityIdx", outSensIdx.take(nSens).toReadableArray())
                    putArray("sensitivityCorr", outSensCorr.take(nSens).toReadableArray())
                }

                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("MONTE_CARLO_ERROR", e.message, e)
            }
        }
    }

    // ── getVersion ─────────────────────────────────────────────────────────────

    @ReactMethod
    fun getVersion(promise: Promise) {
        promise.resolve(nativeGetVersion())
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private fun ReadableArray.toDoubleArray(): DoubleArray =
        DoubleArray(size()) { i -> getDouble(i) }

    private fun List<Double>.toReadableArray(): WritableArray =
        Arguments.createArray().also { arr -> forEach { arr.pushDouble(it) } }

    private fun List<Int>.toReadableArray(): WritableArray =
        Arguments.createArray().also { arr -> forEach { arr.pushInt(it) } }

    private fun DoubleArray.take(n: Int) = toList().subList(0, n.coerceAtMost(size))
    private fun IntArray.take(n: Int) = toList().subList(0, n.coerceAtMost(size))
}
