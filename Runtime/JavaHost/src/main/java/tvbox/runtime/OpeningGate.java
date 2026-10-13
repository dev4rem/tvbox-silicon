package tvbox.runtime;

import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Lets one caller at a time open a plugin (runtime start-up or spider init, which can take
 * minutes), or use one spider. What the viewer is waiting on (home, detail, playback) goes before
 * searches that are still waiting, and a request the app abandoned stops waiting instead of
 * opening a plugin nobody wants.
 *
 * A request's stop time is an {@link AtomicLong}: 0 while it may run, otherwise the epoch
 * milliseconds at which it must end (the app abandoned it, or its deadline). The host checks it
 * wherever the plugin waits. A spider gate is {@code replaceable}: when its holder is still running
 * well past its stop time (a plugin waiting in a way the host cannot reach), the requests behind
 * it get {@link Stuck}, and the host retires that spider and opens a fresh one.
 */
final class OpeningGate {
    /** How long a stopped request may take to unwind before its spider counts as stuck. */
    static final long STUCK_GRACE_MILLIS = Long.getLong("tvbox.stuckGraceMillis", 15_000);

    private final boolean replaceable;
    private boolean held, retired;
    private AtomicLong holder;
    private int interactiveWaiting;

    OpeningGate() { this(false); }
    OpeningGate(boolean replaceable) { this.replaceable = replaceable; }

    /** Waits for the gate; throws CancellationException once {@code stopAt} passes. */
    synchronized void enter(boolean search, AtomicLong stopAt) throws InterruptedException {
        if (!search) interactiveWaiting++;
        try {
            while (true) {
                if (retired) throw new Stuck();
                if (!held && !(search && interactiveWaiting > 0)) break;
                if (stopped(stopAt)) throw new CancellationException("The app no longer needs this request.");
                if (held && stuck()) throw new Stuck();
                // Cancellation does not notify this gate; recheck it every quarter second.
                wait(250);
            }
            if (stopped(stopAt)) throw new CancellationException("The app no longer needs this request.");
            held = true; holder = stopAt;
        } finally {
            if (!search) interactiveWaiting--;
        }
    }

    synchronized void leave() {
        held = false; holder = null;
        notifyAll();
    }

    /** Whether the request holding a replaceable gate overran its stop time by the grace period. */
    synchronized boolean stuck() {
        if (!replaceable || !held || holder == null) return false;
        long at = holder.get();
        return at > 0 && System.currentTimeMillis() >= at + STUCK_GRACE_MILLIS;
    }

    synchronized boolean retired() { return retired; }

    /** Turns away every later caller: the spider behind this gate is being replaced. */
    synchronized void retire() {
        retired = true;
        notifyAll();
    }

    /** Whether the request is a search; searches yield to everything else. */
    static boolean search(org.json.JSONObject input) {
        var params = input.optJSONObject("params");
        return params != null && params.has("wd");
    }

    /** The request's stop time, set by the app's {@code cancel} command; null when it has none. */
    static AtomicLong cancelled(org.json.JSONObject input) {
        return input.opt("stopAt") instanceof AtomicLong stop ? stop : null;
    }

    /** A request served again after a sign-in gets its full deadline back; a cancelled one stays cancelled. */
    static void freshDeadline(org.json.JSONObject input) {
        AtomicLong stop = cancelled(input);
        long now = System.currentTimeMillis();
        if (stop != null) stop.updateAndGet(at -> at > now ? 0 : at);
        System.err.println("PLUGIN_RETRY_SIGNED_IN " + java.time.LocalTime.now().withNano(0));
    }

    static boolean stopped(AtomicLong stopAt) {
        long at = stopAt == null ? 0 : stopAt.get();
        return at > 0 && System.currentTimeMillis() >= at;
    }

    /** The spider behind the gate is stuck in a request that will not end; open a fresh one. */
    static final class Stuck extends RuntimeException {
        Stuck() { super("The source is stuck in an earlier request"); }
    }
}
