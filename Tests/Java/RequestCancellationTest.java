import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;
import tvbox.runtime.InProcessHost;

public final class RequestCancellationTest {
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

    public static void main(String[] args) throws Exception {
        // A cancel can reach the host before its request; the request then never opens a plugin.
        check(new JSONObject(InProcessHost.request("{\"command\":\"cancel\",\"request\":\"early\"}")).getBoolean("result"), "Cancel was refused");
        JSONObject answer = new JSONObject(InProcessHost.request("{\"request\":\"early\",\"session\":\"s\",\"cache\":\"/nonexistent\",\"params\":{\"wd\":\"x\"}}"));
        check("cancelled".equals(answer.optString("errorCode")), "Cancelled request still ran: " + answer);

        Class<?> type = Class.forName("tvbox.runtime.OpeningGate");
        var constructor = type.getDeclaredConstructor(); constructor.setAccessible(true);
        Object gate = constructor.newInstance();
        Method enter = type.getDeclaredMethod("enter", boolean.class, AtomicLong.class); enter.setAccessible(true);
        Method leave = type.getDeclaredMethod("leave"); leave.setAccessible(true);

        // The viewer's request opens before a search that was already waiting.
        enter.invoke(gate, false, null);
        List<String> order = new CopyOnWriteArrayList<>();
        Thread search = opener(gate, enter, leave, true, null, order, new AtomicReference<>());
        Thread.sleep(100);
        Thread detail = opener(gate, enter, leave, false, null, order, new AtomicReference<>());
        Thread.sleep(100);
        leave.invoke(gate);
        search.join(5000); detail.join(5000);
        check(order.equals(List.of("detail", "search")), "Searches went first: " + order);

        // An abandoned opener stops waiting.
        enter.invoke(gate, false, null);
        AtomicLong cancelled = new AtomicLong();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread waiting = opener(gate, enter, leave, true, cancelled, new CopyOnWriteArrayList<>(), failure);
        Thread.sleep(100);
        cancelled.set(System.currentTimeMillis());
        waiting.join(2000);
        check(!waiting.isAlive(), "Cancelled opener kept waiting");
        check(failure.get() instanceof CancellationException, "Cancelled opener did not fail with cancellation: " + failure.get());
        leave.invoke(gate);
        cancelWaitingSourceRequest(constructor.newInstance());
        replaceStuckRuntime();
        restartAfterSignIn();
        System.out.println("RequestCancellationTest passed: early cancel, viewer before searches, abandoned openers stop, stuck runtimes replaced");
    }

    /** A warm single-source runtime must release a cancelled waiter without running its plugin. */
    private static void cancelWaitingSourceRequest(Object requestGate) throws Exception {
        var type = Class.forName("tvbox.runtime.InProcessHost$Runtime");
        var constructor = type.getDeclaredConstructors()[0]; constructor.setAccessible(true);
        var loader = new java.net.URLClassLoader(new java.net.URL[0], RequestCancellationTest.class.getClassLoader());
        var plugin = new BlockingPlugin();
        Object runtime = constructor.newInstance(loader, plugin, false, java.nio.file.Path.of("/tmp"), requestGate);
        var field = InProcessHost.class.getDeclaredField("runtimes"); field.setAccessible(true);
        @SuppressWarnings("unchecked") var runtimes = (java.util.Map<String, Object>) field.get(null);
        synchronized (InProcessHost.class) { runtimes.put("session:cancellation-test", runtime); }
        AtomicReference<String> answer = new AtomicReference<>();
        Thread active = new Thread(() -> InProcessHost.request("{\"request\":\"active\",\"session\":\"cancellation-test\",\"params\":{\"play\":\"1\"}}"));
        Thread waiting = new Thread(() -> answer.set(InProcessHost.request("{\"request\":\"waiting\",\"session\":\"cancellation-test\",\"params\":{\"wd\":\"x\"}}")));
        try {
            active.start();
            check(plugin.started.await(2, java.util.concurrent.TimeUnit.SECONDS), "Plugin did not start");
            waiting.start();
            long deadline = System.nanoTime() + 2_000_000_000L;
            while (waiting.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) Thread.sleep(5);
            check(waiting.getState() == Thread.State.TIMED_WAITING, "Request did not wait for the source");
            InProcessHost.request("{\"command\":\"cancel\",\"request\":\"waiting\"}");
            waiting.join(2000);
            check(!waiting.isAlive(), "Cancelled source waiter kept its worker slot");
            check("cancelled".equals(new JSONObject(answer.get()).optString("errorCode")), "Wrong cancellation response: " + answer.get());
            check(plugin.calls.get() == 1, "Abandoned request entered the plugin");
            var busyField = InProcessHost.class.getDeclaredField("busy"); busyField.setAccessible(true);
            synchronized (InProcessHost.class) {
                var busy = (java.util.Map<?, ?>) busyField.get(null);
                check(Integer.valueOf(1).equals(busy.get(runtime)), "Cancelled request kept the runtime busy");
            }
        } finally {
            plugin.release.countDown(); active.join(2000); waiting.join(2000);
            InProcessHost.closeAll();
        }
    }

    /**
     * A request that keeps running long after it was cancelled (a plugin waiting where the host
     * cannot reach it) must not hold its source: the next request retires that runtime instead of
     * waiting forever, and the retired runtime closes once the stuck request returns.
     */
    private static void replaceStuckRuntime() throws Exception {
        var type = Class.forName("tvbox.runtime.InProcessHost$Runtime");
        var constructor = type.getDeclaredConstructors()[0]; constructor.setAccessible(true);
        var gateType = Class.forName("tvbox.runtime.OpeningGate");
        var gateConstructor = gateType.getDeclaredConstructor(boolean.class); gateConstructor.setAccessible(true);
        var loader = new java.net.URLClassLoader(new java.net.URL[0], RequestCancellationTest.class.getClassLoader());
        var plugin = new BlockingPlugin();
        Object runtime = constructor.newInstance(loader, plugin, false, java.nio.file.Path.of("/tmp"), gateConstructor.newInstance(true));
        var field = InProcessHost.class.getDeclaredField("runtimes"); field.setAccessible(true);
        @SuppressWarnings("unchecked") var runtimes = (java.util.Map<String, Object>) field.get(null);
        var retiredField = InProcessHost.class.getDeclaredField("retired"); retiredField.setAccessible(true);
        var retired = (java.util.Set<?>) retiredField.get(null);
        synchronized (InProcessHost.class) { runtimes.put("session:stuck-test", runtime); }
        AtomicReference<String> answer = new AtomicReference<>();
        Thread stuck = new Thread(() -> InProcessHost.request("{\"request\":\"stuck\",\"session\":\"stuck-test\",\"params\":{\"play\":\"1\"}}"));
        Thread next = new Thread(() -> answer.set(InProcessHost.request("{\"request\":\"next\",\"session\":\"stuck-test\",\"cache\":\"/nonexistent\",\"jar\":\"/nonexistent.jar\",\"params\":{\"ids\":\"1\"}}")));
        try {
            stuck.start();
            check(plugin.started.await(2, java.util.concurrent.TimeUnit.SECONDS), "Plugin did not start");
            InProcessHost.request("{\"command\":\"cancel\",\"request\":\"stuck\"}");
            next.start();
            next.join(5000);
            check(!next.isAlive(), "A request waited forever behind a stuck one");
            check(answer.get() != null && !answer.get().contains("\"result\""), "The stuck runtime served another request: " + answer.get());
            synchronized (InProcessHost.class) {
                check(runtimes.get("session:stuck-test") != runtime, "The stuck runtime stayed in service");
                check(retired.contains(runtime), "The stuck runtime was not retired");
            }
            check(plugin.calls.get() == 1, "A request entered the stuck spider");
            plugin.release.countDown();
            stuck.join(2000);
            synchronized (InProcessHost.class) { check(!retired.contains(runtime), "The retired runtime stayed open after its request returned"); }
            check(plugin.closed, "The retired runtime was not closed");
        } finally {
            plugin.release.countDown(); stuck.join(2000); next.join(2000);
            InProcessHost.closeAll();
        }
    }

    /** After the plugin's own sign-in, the source restarts (a fresh spider reads the account) and the request is served again. */
    private static void restartAfterSignIn() throws Exception {
        var type = Class.forName("tvbox.runtime.InProcessHost$Runtime");
        var constructor = type.getDeclaredConstructors()[0]; constructor.setAccessible(true);
        var gateType = Class.forName("tvbox.runtime.OpeningGate");
        var gateConstructor = gateType.getDeclaredConstructor(boolean.class); gateConstructor.setAccessible(true);
        var loader = new java.net.URLClassLoader(new java.net.URL[0], RequestCancellationTest.class.getClassLoader());
        var plugin = new SigningInPlugin();
        Object runtime = constructor.newInstance(loader, plugin, false, java.nio.file.Path.of("/tmp"), gateConstructor.newInstance(true));
        var field = InProcessHost.class.getDeclaredField("runtimes"); field.setAccessible(true);
        @SuppressWarnings("unchecked") var runtimes = (java.util.Map<String, Object>) field.get(null);
        synchronized (InProcessHost.class) { runtimes.put("session:signin-test", runtime); }
        try {
            String answer = InProcessHost.request("{\"request\":\"signin\",\"session\":\"signin-test\",\"cache\":\"/nonexistent\",\"jar\":\"/nonexistent.jar\",\"params\":{\"play\":\"1\"}}");
            check(plugin.calls.get() == 1, "The signed-in spider was asked again");
            synchronized (InProcessHost.class) { check(runtimes.get("session:signin-test") != runtime, "The source kept its old spider"); }
            check(plugin.closed, "The old spider stayed open");
            // The retry opened a fresh runtime (here a missing jar, so it fails to open, not to sign in).
            check(!new JSONObject(answer).has("result") && !answer.contains("SignedIn"), "Unexpected answer: " + answer);
        } finally { InProcessHost.closeAll(); }
    }

    public static final class SigningInPlugin {
        volatile boolean closed;
        final java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
        public String request(JSONObject input) throws Exception {
            calls.incrementAndGet();
            var signedIn = Class.forName("tvbox.runtime.HttpDiagnostics$SignedIn").getDeclaredConstructor();
            signedIn.setAccessible(true);
            throw (Error) signedIn.newInstance();
        }
        public void close() { closed = true; }
    }

    public static final class BlockingPlugin {
        volatile boolean closed;
        final java.util.concurrent.CountDownLatch started = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
        public String request(JSONObject input) throws InterruptedException {
            calls.incrementAndGet(); started.countDown(); release.await(); return "{}";
        }
        public void close() { closed = true; }
    }

    private static Thread opener(Object gate, Method enter, Method leave, boolean search, AtomicLong cancelled,
                                 List<String> order, AtomicReference<Throwable> failure) {
        Thread thread = new Thread(() -> {
            try {
                enter.invoke(gate, search, cancelled);
                order.add(search ? "search" : "detail");
                leave.invoke(gate);
            } catch (java.lang.reflect.InvocationTargetException error) { failure.set(error.getCause()); }
            catch (Exception error) { failure.set(error); }
        });
        thread.start();
        return thread;
    }
}
