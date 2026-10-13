package android.os;

/** Monotonic timing for Java plugins; never bind android.jar's native declarations. */
public final class SystemClock {
    public static long elapsedRealtime() { return System.nanoTime() / 1_000_000L; }
    public static long elapsedRealtimeNanos() { return System.nanoTime(); }
    public static long uptimeMillis() { return elapsedRealtime(); }
    public static long currentThreadTimeMillis() {
        long nanos = java.lang.management.ManagementFactory.getThreadMXBean().getCurrentThreadCpuTime();
        return Math.max(0, nanos / 1_000_000L);
    }
    public static void sleep(long milliseconds) {
        // Plugins wait for a sign-in or a result by polling here, some of them forever. QR helpers
        // may run on a plugin executor while the playback thread polls. Check in a few times a
        // second, so a login handoff, a request the app abandoned or a passed deadline ends the wait.
        tvbox.runtime.HttpDiagnostics.checkpoint();
        long started = elapsedRealtime();
        long remaining = milliseconds;
        boolean interrupted = false;
        while (remaining > 0) {
            try { Thread.sleep(Math.min(remaining, 250)); }
            catch (InterruptedException interruption) { interrupted = true; }
            remaining = milliseconds - (elapsedRealtime() - started);
            if (remaining > 0) tvbox.runtime.HttpDiagnostics.checkpoint();
        }
        if (interrupted) Thread.currentThread().interrupt();
    }
}
