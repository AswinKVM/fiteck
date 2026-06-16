package com.fitness.tracker

// ═══════════════════════════════════════════════════════════════════════
// StepSensorPlugin.kt
//
// Place this file at:
//   android/app/src/main/kotlin/com/fitness/tracker/StepSensorPlugin.kt
//
// Then register it in MainActivity.kt (see bottom of this file).
//
// What this does:
//   Bridges Android's TYPE_STEP_COUNTER hardware sensor to Flutter.
//   The hardware chip inside the phone counts steps with its own DSP —
//   it's orders of magnitude more accurate than any software algorithm.
//
// How it works:
//   MethodChannel → check availability, start/stop
//   EventChannel  → stream step counts back to Dart in real time
// ═══════════════════════════════════════════════════════════════════════

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class StepSensorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    SensorEventListener, EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var sensorManager: SensorManager
    private var stepSensor: Sensor? = null
    private var eventSink: EventChannel.EventSink? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context       = binding.applicationContext
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        stepSensor    = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)

        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "com.fitness.tracker/step_sensor"
        ).also { it.setMethodCallHandler(this) }

        eventChannel = EventChannel(
            binding.binaryMessenger,
            "com.fitness.tracker/step_events"
        ).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        sensorManager.unregisterListener(this)
    }

    // ── MethodChannel calls from Dart ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAvailable" -> result.success(stepSensor != null)
            "startListening" -> {
                if (stepSensor != null) {
                    sensorManager.registerListener(
                        this, stepSensor,
                        SensorManager.SENSOR_DELAY_NORMAL
                    )
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            "stopListening" -> {
                sensorManager.unregisterListener(this)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ── SensorEventListener — fires when hardware counts a step ──

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type == Sensor.TYPE_STEP_COUNTER) {
            // event.values[0] = cumulative steps since last boot (never resets)
            eventSink?.success(event.values[0].toLong())
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // ── EventChannel StreamHandler ──

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        if (stepSensor != null) {
            sensorManager.registerListener(
                this, stepSensor,
                SensorManager.SENSOR_DELAY_NORMAL
            )
        } else {
            sink?.error("NO_SENSOR", "TYPE_STEP_COUNTER not available", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        eventSink = null
    }
}

// ═══════════════════════════════════════════════════════════════════════
// REGISTER IN MAINACTIVITY.KT
//
// Open android/app/src/main/kotlin/com/fitness/tracker/MainActivity.kt
// and make it look like this:
//
// package com.fitness.tracker
//
// import io.flutter.embedding.android.FlutterActivity
// import io.flutter.embedding.engine.FlutterEngine
//
// class MainActivity : FlutterActivity() {
//     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
//         super.configureFlutterEngine(flutterEngine)
//         flutterEngine.plugins.add(StepSensorPlugin())
//     }
// }
// ═══════════════════════════════════════════════════════════════════════