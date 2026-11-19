package dev.fluttercommunity.plus.sensors

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.util.HandlerCompat

internal class StreamHandlerImpl(
    private val sensorManager: SensorManager,
    private val sensorType: Int,
    // MotoCam patch: the background thread that averaging listeners run on.
    private val sensorHandler: () -> Handler
) : EventChannel.StreamHandler {
    private var sensorEventListener: SensorEventListener? = null

    private var sensor: Sensor? = null

    // MotoCam patch: kept so a period change can re-register with the other
    // kind of listener.
    private var events: EventSink? = null

    private val mainHandler = HandlerCompat.createAsyncHandler(Looper.getMainLooper())

    private var timestampMicroAtBoot: Long = System.currentTimeMillis() * 1000 - SystemClock.elapsedRealtimeNanos() / 1000

    var samplingPeriod = 200000
        set(value) {
            field = value
            updateRegistration()
        }

    override fun onListen(arguments: Any?, events: EventSink) {
        sensor = sensorManager.getDefaultSensor(sensorType)
        if (sensor != null) {
            this.events = events
            register()
        } else {
            events.error(
                "NO_SENSOR",
                "Sensor not found",
                "It seems that your device has no ${getSensorName(sensorType)} sensor"
            )
        }
    }

    override fun onCancel(arguments: Any?) {
        if (sensor != null) {
            unregister()
            events = null
        }
    }

    private fun updateRegistration() {
        if (sensorEventListener != null) {
            unregister()
            register()
        }
    }

    // MotoCam patch: a period of AVERAGE_FROM_PERIOD_US or longer gets an
    // averaging listener on the sensor thread; anything faster keeps the
    // upstream listener on the main looper and delivers every sample.
    private fun register() {
        val sink = events ?: return
        val listener: SensorEventListener
        if (samplingPeriod >= AVERAGE_FROM_PERIOD_US) {
            listener = AveragingListener(sink, samplingPeriod)
            sensorManager.registerListener(listener, sensor, samplingPeriod, sensorHandler())
        } else {
            listener = createSensorEventListener(sink)
            sensorManager.registerListener(listener, sensor, samplingPeriod)
        }
        sensorEventListener = listener
    }

    private fun unregister() {
        val listener = sensorEventListener ?: return
        sensorManager.unregisterListener(listener)
        (listener as? AveragingListener)?.active = false
        sensorEventListener = null
    }

    private fun getSensorName(sensorType: Int): String {
        return when (sensorType) {
            Sensor.TYPE_ACCELEROMETER -> "Accelerometer"
            Sensor.TYPE_LINEAR_ACCELERATION -> "User Accelerometer"
            Sensor.TYPE_GYROSCOPE -> "Gyroscope"
            Sensor.TYPE_MAGNETIC_FIELD -> "Magnetometer"
            Sensor.TYPE_PRESSURE -> "Barometer"
            else -> "Undefined"
        }
    }

    private fun createSensorEventListener(events: EventSink): SensorEventListener {
        return object : SensorEventListener {
            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

            override fun onSensorChanged(event: SensorEvent) {
                val sensorValues = DoubleArray(event.values.size + 1)
                event.values.forEachIndexed { index, value ->
                    sensorValues[index] = value.toDouble()
                }

                val timestampMicro = timestampMicroAtBoot + (event.timestamp / 1000)
                sensorValues[event.values.size] = timestampMicro.toDouble()

                events.success(sensorValues)
            }
        }
    }

    // MotoCam patch: runs on the sensor thread and posts one averaged sample
    // per period to the main thread, where EventSink calls must run.
    private inner class AveragingListener(
        private val sink: EventSink,
        samplingPeriodUs: Int
    ) : SensorEventListener {
        private val averager = BlockAverager(samplingPeriodUs * 1000L)

        // Cleared on the main thread when the listener is unregistered, so a
        // sample posted before that is dropped instead of delivered.
        @Volatile
        var active = true

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

        override fun onSensorChanged(event: SensorEvent) {
            val mean = averager.add(event.values, event.timestamp) ?: return
            val sensorValues = mean.values.copyOf(mean.values.size + 1)
            sensorValues[mean.values.size] =
                (timestampMicroAtBoot + mean.timestampNs / 1000).toDouble()
            mainHandler.post {
                if (active) {
                    sink.success(sensorValues)
                }
            }
        }
    }

    companion object {
        // MotoCam patch: periods of 50 ms or longer (SensorInterval.uiInterval
        // and normalInterval) are averaged down to the requested rate, because
        // some phones deliver about 100 samples a second whatever is asked.
        // gameInterval (20 ms), fastestInterval and the SENSOR_DELAY constants
        // keep every sample.
        private const val AVERAGE_FROM_PERIOD_US = 50_000
    }
}
