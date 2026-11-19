package dev.fluttercommunity.plus.sensors

/**
 * MotoCam patch: averages sensor samples into one sample per [periodNs], on
 * the sensor's own clock.
 *
 * Some phones deliver about 100 samples a second whatever period is
 * requested. Keeping one sample in N would alias vibration into the result,
 * so every sample of a block is averaged instead. Blocks are phase-locked to
 * the period: the output rate equals 1 / period on average. A sample closes
 * the block when it lands within half a source interval (at most half a
 * period) of the block's end; it is part of the block it closes. The output
 * carries the closing sample's timestamp.
 *
 * Not thread-safe: call [add] from one thread only.
 */
internal class BlockAverager(private val periodNs: Long) {
    class Sample(val values: DoubleArray, val timestampNs: Long)

    private var sums: DoubleArray? = null
    private var count = 0
    private var blockEndNs = 0L
    private var lastTimestampNs = 0L

    /** Adds one sample; returns the block mean when this sample closes a block. */
    fun add(values: FloatArray, timestampNs: Long): Sample? {
        var sum = sums
        if (sum == null || sum.size != values.size) {
            sum = DoubleArray(values.size)
            sums = sum
            count = 0
            blockEndNs = timestampNs + periodNs
            lastTimestampNs = timestampNs
        } else if (timestampNs < blockEndNs - 2 * periodNs) {
            // The clock went back: restart the schedule instead of waiting
            // for it to catch up.
            blockEndNs = timestampNs + periodNs
        }
        for (i in values.indices) {
            sum[i] += values[i].toDouble()
        }
        count++

        val sourceIntervalNs = (timestampNs - lastTimestampNs).coerceAtLeast(0L)
        lastTimestampNs = timestampNs
        val slackNs = minOf(sourceIntervalNs / 2, periodNs / 2)
        if (timestampNs < blockEndNs - slackNs) {
            return null
        }

        val mean = DoubleArray(sum.size) { sum[it] / count }
        sum.fill(0.0)
        count = 0
        blockEndNs += periodNs
        if (timestampNs >= blockEndNs) {
            // A gap of more than a period: resync instead of bursting.
            blockEndNs = timestampNs + periodNs
        }
        return Sample(mean, timestampNs)
    }
}
