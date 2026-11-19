package dev.fluttercommunity.plus.sensors

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class BlockAveragerTest {
    private val uiPeriodNs = 66_667_000L // SensorInterval.uiInterval

    private fun run(
        averager: BlockAverager,
        timestampsNs: List<Long>,
        value: (Int) -> Float = { 1f }
    ): List<BlockAverager.Sample> = timestampsNs.mapIndexedNotNull { i, t ->
        averager.add(floatArrayOf(value(i), 2f, 3f), t)
    }

    private fun source(hz: Double, seconds: Double, startNs: Long = 1_000_000_000L): List<Long> =
        (0 until (hz * seconds).toInt()).map { startNs + (it * 1e9 / hz).toLong() }

    @Test
    fun about100HzSourceGivesTheRequested15Hz() {
        val out = run(BlockAverager(uiPeriodNs), source(100.9, 10.0))
        assertTrue("got ${out.size}", out.size in 148..151)
        out.zipWithNext().forEach { (a, b) ->
            val gapMs = (b.timestampNs - a.timestampNs) / 1e6
            assertTrue("interval $gapMs ms", gapMs in 55.0..80.0)
        }
    }

    @Test
    fun about200HzSourceGivesTheRequested15Hz() {
        val out = run(BlockAverager(uiPeriodNs), source(200.0, 10.0))
        assertTrue("got ${out.size}", out.size in 148..151)
    }

    @Test
    fun averagesEveryAxisInsteadOfPickingOneSample() {
        // A 50 Hz square wave on x: one-in-N picking aliases it to +1 or -1.
        val out = run(BlockAverager(uiPeriodNs), source(100.0, 5.0)) { i ->
            if (i % 2 == 0) 1f else -1f
        }
        assertTrue(out.isNotEmpty())
        out.forEach {
            assertTrue("x ${it.values[0]}", abs(it.values[0]) <= 0.2)
            assertEquals(2.0, it.values[1], 1e-9)
            assertEquals(3.0, it.values[2], 1e-9)
        }
    }

    @Test
    fun slowerSourcePassesEverySampleAfterTheFirst() {
        val out = run(BlockAverager(uiPeriodNs), source(5.0, 4.0)) { it.toFloat() }
        assertEquals(19, out.size)
        // From the second output on, each block holds one sample.
        out.drop(1).forEachIndexed { i, s -> assertEquals((i + 2).toDouble(), s.values[0], 1e-9) }
    }

    @Test
    fun gapResyncsWithoutABurst() {
        val before = source(100.0, 1.0)
        val after = source(100.0, 1.0, startNs = before.last() + 500_000_000L)
        val out = run(BlockAverager(uiPeriodNs), before + after)
        out.zipWithNext().forEach { (a, b) ->
            assertTrue((b.timestampNs - a.timestampNs) / 1e6 >= 55.0)
        }
        assertTrue("got ${out.size}", out.size in 28..31)
    }

    @Test
    fun clockGoingBackDoesNotStallOutput() {
        val first = source(100.0, 1.0, startNs = 20_000_000_000L)
        val second = source(100.0, 1.0, startNs = 5_000_000_000L)
        val averager = BlockAverager(uiPeriodNs)
        run(averager, first)
        val out = run(averager, second)
        assertTrue("got ${out.size}", out.size in 13..16)
    }
}
