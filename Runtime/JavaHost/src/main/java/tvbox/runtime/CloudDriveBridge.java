package tvbox.runtime;

import com.sun.net.httpserver.HttpServer;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Per-process loopback capability for CatVod configuration and proxy responses. */
public final class CloudDriveBridge implements AutoCloseable {
    @FunctionalInterface public interface Proxy { Object[] invoke(Map<String,String> params) throws Exception; }
    @FunctionalInterface public interface DriveProxy { Object[] invoke(Map<String,String> params, String path, Map<String,String> headers) throws Exception; }
    private volatile DriveProxy driveProxy;
    private static volatile CloudDriveBridge current;
    // Concurrent searches run on separate worker threads; each must see its own source's proxy.
    // `current` stays as the fallback for threads a plugin starts itself.
    private static final ThreadLocal<CloudDriveBridge> active = new ThreadLocal<>();
    private static CloudDriveBridge bridge() {
        CloudDriveBridge local = active.get();
        return local != null ? local : current;
    }
    private volatile HttpServer server;
    private boolean closed;
    private final Set<Integer> ports = ConcurrentHashMap.newKeySet();
    private ExecutorService workers = newWorkers();
    private static ExecutorService newWorkers() {
        return Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "cloud-proxy"); t.setDaemon(true); return t; });
    }
    private final String capability = UUID.randomUUID().toString();
    private final Map<String, byte[]> files = new HashMap<>();
    private final Path activity;
    private volatile Proxy proxy;
    private final java.util.concurrent.atomic.AtomicInteger configurationReads = new java.util.concurrent.atomic.AtomicInteger();

    public CloudDriveBridge(Path cache) throws IOException {
        activity = cache.resolve("proxy-active");
        server = listen(0);
        current = this;
        startStandardPort();
    }

    private HttpServer listen(int port) throws IOException {
        HttpServer listener = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 16);
        listener.setExecutor(workers);
        listener.createContext("/", exchange -> {
            try {
                String path = exchange.getRequestURI().getPath();
                if (!path.startsWith("/" + capability + "/") || exchange.getRequestHeaders().containsKey("Origin")) {
                    exchange.sendResponseHeaders(403, -1); return;
                }
                String method = exchange.getRequestMethod();
                if (!method.equals("GET") && !method.equals("HEAD")) { exchange.sendResponseHeaders(405, -1); return; }
                String resource = path.substring(capability.length() + 2);
                if (resource.equals("health")) { exchange.sendResponseHeaders(204, -1); return; }
                if (files.containsKey(resource)) {
                    configurationReads.incrementAndGet();
                    byte[] bytes = files.get(resource);
                    exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
                    exchange.getResponseHeaders().set("Cache-Control", "no-store");
                    exchange.sendResponseHeaders(200, method.equals("HEAD") ? -1 : bytes.length);
                    if (!method.equals("HEAD")) exchange.getResponseBody().write(bytes);
                    return;
                }
                relay(exchange, resource, method);
            } catch (Exception error) {
                // Never print request URLs, credentials, or upstream exception messages.
                System.err.println("CLOUD_PROXY_ERROR " + error.getClass().getSimpleName());
                try { exchange.sendResponseHeaders(502, -1); } catch (IOException ignored) { }
            } finally { exchange.close(); }
        });
        listener.start();
        ports.add(listener.getAddress().getPort());
        return listener;
    }

    /** Apple can invalidate sockets while the app is suspended without destroying its JVM. */
    public synchronized void ensureAvailable() throws IOException {
        if (closed) throw new IOException("Plugin proxy was closed");
        HttpURLConnection probe = null;
        try {
            probe = (HttpURLConnection)URI.create(base() + "health").toURL().openConnection(java.net.Proxy.NO_PROXY);
            probe.setRequestMethod("HEAD"); probe.setConnectTimeout(750); probe.setReadTimeout(1500);
            probe.setUseCaches(false); probe.setRequestProperty("Connection", "close");
            if (probe.getResponseCode() == 204) return;
        } catch (IOException unavailable) {
            // Recover the listener; the spider and its account/session state are still valid.
        } finally { if (probe != null) probe.disconnect(); }
        int port = server.getAddress().getPort();
        server.stop(0);
        workers.shutdownNow(); workers = newWorkers();
        try { server = listen(port); }
        catch (BindException occupied) { server = listen(0); }
        System.err.println("CLOUD_PROXY_RECOVERED");
    }

    public String recoverProxy(String address) throws IOException {
        final URI uri;
        try { uri = URI.create(address); } catch (IllegalArgumentException invalid) { return null; }
        if (!"http".equals(uri.getScheme()) || !"127.0.0.1".equals(uri.getHost())
                || !ports.contains(uri.getPort()) || uri.getRawPath() == null
                || !uri.getRawPath().startsWith("/" + capability + "/")) return null;
        ensureAvailable();
        return base() + uri.getRawPath().substring(capability.length() + 2)
            + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery());
    }

    /**
     * The CDN address and headers behind one of this bridge's drive or media files, as JSON
     * {@code {"url","headers","length"}}, or null. It asks the plugin's proxy for two bytes and
     * records the upstream range request the plugin makes to answer them; when those bytes were
     * already cached, a second probe in the middle of the file forces a fresh request. A proxy
     * that does not answer with a byte range (a playlist, a page) is left alone at once.
     */
    public String directMedia(String address) throws Exception {
        String local = recoverProxy(address);
        if (local == null) return null;
        String path = URI.create(local).getRawPath();
        if (!path.contains("/drive/") && !path.endsWith("/media")) return null;
        synchronized (CloudDriveBridge.class) {
            try {
                long total = -1;
                for (int probe = 0; probe < 2; probe++) {
                    HttpDiagnostics.captureMedia(true);
                    long first = probe == 0 || total < 4 ? 0 : total / 2;
                    HttpURLConnection connection = (HttpURLConnection)URI.create(local).toURL().openConnection(java.net.Proxy.NO_PROXY);
                    try {
                        connection.setConnectTimeout(5000); connection.setReadTimeout(20000); connection.setUseCaches(false);
                        connection.setRequestProperty("Range", "bytes=" + first + "-" + (first + 1));
                        int status = connection.getResponseCode();
                        String range = connection.getHeaderField("Content-Range");
                        var match = range == null ? null : java.util.regex.Pattern.compile("bytes \\d+-\\d+/(\\d+)").matcher(range);
                        if (match != null && match.matches()) total = Long.parseLong(match.group(1));
                        if (status != 206 || total < 0) {
                            System.err.println("CLOUD_DIRECT_MEDIA not a ranged file status=" + status);
                            return null;
                        }
                        try (InputStream body = connection.getInputStream()) { body.readNBytes(2); }
                    } finally { connection.disconnect(); }
                    // The plugin may still be finishing the upstream request when our two bytes arrive.
                    for (int wait = 0; wait < 50 && HttpDiagnostics.capturedMedia() == null; wait++) Thread.sleep(100);
                    HttpDiagnostics.MediaRequest media = HttpDiagnostics.capturedMedia();
                    if (media != null && (total < 0 || media.length == total)) {
                        System.err.println("CLOUD_DIRECT_MEDIA length=" + media.length + " probe=" + probe);
                        return new JSONObject().put("url", media.url).put("headers", new JSONObject(media.headers)).put("length", media.length).toString();
                    }
                }
                System.err.println("CLOUD_DIRECT_MEDIA unavailable");
                return null;
            } finally { HttpDiagnostics.captureMedia(false); }
        }
    }

    /** Hands a media or drive request to the plugin's proxy and streams its answer back. */
    private void relay(com.sun.net.httpserver.HttpExchange exchange, String resource, String method) throws Exception {
        if ((!resource.equals("media") || proxy == null) && (!resource.startsWith("drive/") || driveProxy == null)) { exchange.sendResponseHeaders(404, -1); return; }
        Map<String,String> params = new HashMap<>();
        String query = exchange.getRequestURI().getRawQuery();
        if (query != null) for (String pair : query.split("&")) {
            String[] parts = pair.split("=", 2);
            params.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8), parts.length == 2 ? URLDecoder.decode(parts[1], StandardCharsets.UTF_8) : "");
        }
        Map<String,String> headers = new HashMap<>();
        exchange.getRequestHeaders().forEach((key, values) -> headers.put(key.toLowerCase(Locale.ROOT), String.join(",", values)));
        touch();
        Object[] response;
        if (resource.startsWith("drive/")) {
            String route = resource.substring("drive".length());
            if (route.startsWith("/proxy")) route = route.substring("/proxy".length());
            response = driveProxy.invoke(params, route, headers);
        } else { params.putAll(headers); response = proxy.invoke(params); }
        if (response == null || response.length < 3 || !(response[0] instanceof Number) || !(response[2] instanceof InputStream)) {
            exchange.sendResponseHeaders(502, -1); return;
        }
        try (InputStream body = (InputStream) response[2]) {
            exchange.getResponseHeaders().set("Content-Type", String.valueOf(response[1]));
            long length = -1;
            if (response.length > 3 && response[3] instanceof Map<?,?> responseHeaders) {
                for (var entry : responseHeaders.entrySet()) {
                    String key = String.valueOf(entry.getKey());
                    String value = String.valueOf(entry.getValue());
                    if (key.equalsIgnoreCase("content-length")) {
                        try { length = Math.max(-1, Long.parseLong(value)); } catch (NumberFormatException ignored) { }
                        continue;
                    }
                    if (Set.of("connection", "transfer-encoding").contains(key.toLowerCase(Locale.ROOT))) continue;
                    if (key.equalsIgnoreCase("location")) value = rewriteAddress(value);
                    exchange.getResponseHeaders().set(key, value);
                }
            }
            int status = ((Number)response[0]).intValue();
            // Some Android proxies call a range starting at zero "200". AVPlayer
            // needs the partial-response status and length, including its 0-1 probe.
            String range = exchange.getResponseHeaders().getFirst("Content-Range");
            if ((status == 200 || status == 206) && headers.containsKey("range") && range != null) {
                var match = java.util.regex.Pattern.compile("bytes (\\d+)-(\\d+)/(?:\\d+|\\*)").matcher(range);
                if (match.matches()) try {
                    long first = Long.parseLong(match.group(1)), last = Long.parseLong(match.group(2));
                    if (last >= first && last - first < Long.MAX_VALUE) {
                        status = 206;
                        // Android proxies may report the entire file size for a small range.
                        length = last - first + 1;
                    }
                } catch (NumberFormatException ignored) { }
            }
            boolean noBody = method.equals("HEAD") || status == 204 || status == 304 || length == 0;
            if (length >= 0 && noBody) exchange.getResponseHeaders().set("Content-Length", Long.toString(length));
            exchange.sendResponseHeaders(status, noBody ? -1 : length > 0 ? length : 0);
            System.err.println("CLOUD_PROXY_RESPONSE status=" + status + " length=" + length + " head=" + method.equals("HEAD"));
            if (!noBody) {
                byte[] buffer = new byte[64 * 1024]; int count;
                long remaining = length;
                while (remaining != 0 && (count = body.read(buffer, 0, remaining < 0 ? buffer.length : (int)Math.min(buffer.length, remaining))) != -1) {
                    exchange.getResponseBody().write(buffer, 0, count); touch();
                    if (remaining > 0) remaining -= count;
                }
                System.err.println("CLOUD_PROXY_COMPLETE remaining=" + remaining);
            }
        }
    }

    private static HttpServer standard;

    /**
     * TVBox serves plugin proxies at 127.0.0.1:9978 (or the next free port up to 9999), and plugins
     * find it by asking /proxy?do=ck for "ok". Without it they build addresses with port -1 inside
     * playlists and parse URLs that nothing can rewrite. Requests go to the active source's proxy.
     */
    private static synchronized void startStandardPort() {
        if (standard != null) return;
        for (int port = 9978; port <= 9999; port++) {
            HttpServer candidate;
            try { candidate = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 16); }
            catch (IOException busy) { continue; }
            candidate.setExecutor(Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "tvbox-proxy"); t.setDaemon(true); return t; }));
            candidate.createContext("/proxy", exchange -> {
                try {
                    String method = exchange.getRequestMethod();
                    if (exchange.getRequestHeaders().containsKey("Origin")) { exchange.sendResponseHeaders(403, -1); return; }
                    if (!method.equals("GET") && !method.equals("HEAD")) { exchange.sendResponseHeaders(405, -1); return; }
                    String query = exchange.getRequestURI().getRawQuery();
                    if (query != null && (query.equals("do=ck") || query.startsWith("do=ck&"))) {
                        byte[] ok = "ok".getBytes(StandardCharsets.UTF_8);
                        exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
                        exchange.sendResponseHeaders(200, method.equals("HEAD") ? -1 : ok.length);
                        if (!method.equals("HEAD")) exchange.getResponseBody().write(ok);
                        return;
                    }
                    CloudDriveBridge bridge = current;
                    if (bridge == null) { exchange.sendResponseHeaders(404, -1); return; }
                    bridge.relay(exchange, "media", method);
                } catch (Exception error) {
                    System.err.println("CLOUD_PROXY_ERROR " + error.getClass().getSimpleName());
                    try { exchange.sendResponseHeaders(502, -1); } catch (IOException ignored) { }
                } finally { exchange.close(); }
            });
            // The dispatcher thread inherits daemon status from its starter; this server lives for
            // the whole process and must not keep a plugin process alive after its request.
            Thread starter = new Thread(candidate::start, "tvbox-proxy-start");
            starter.setDaemon(true);
            starter.start();
            try { starter.join(); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            standard = candidate;
            return;
        }
    }
    private long lastTouch;
    private synchronized void touch() {
        long now = System.nanoTime();
        if (lastTouch != 0 && now - lastTouch < 1_000_000_000L) return;
        try { Files.writeString(activity, "active"); lastTouch = now; } catch (IOException ignored) { }
    }
    private String base() { return "http://127.0.0.1:" + server.getAddress().getPort() + "/" + capability + "/"; }
    public static String getUrl() {
        CloudDriveBridge bridge = bridge();
        if (bridge == null) throw new IllegalStateException("Plugin proxy is not initialized");
        return bridge.base() + "media";
    }
    /** Newer spider bases call Proxy.getProxyUrlDo("x") for the local proxy with do=x; merged JARs may lack it. */
    public static String getProxyUrlDo(String value) { return getUrl() + "?do=" + value; }
    public static String getOwnProxyUrl() { return getOwnProxyUrl(""); }
    public static String getOwnProxyUrl(String name) {
        CloudDriveBridge bridge = bridge();
        if (bridge == null) throw new IllegalStateException("Plugin proxy is not initialized");
        return bridge.base() + "drive/" + (name.isEmpty() ? "" : "proxy/" + name + "/");
    }
    public void setDriveProxy(ClassLoader loader) {
        driveProxy = (params, path, headers) -> (Object[])loader.loadClass("com.github.catvod.spider.ProxyOrigin")
            .getMethod("proxyDrive", Map.class, String.class, Map.class, String.class, String.class)
            .invoke(null, params, path, headers, "", "");
    }
    public void setDriveProxy(DriveProxy value) { driveProxy = value; }
    public void setProxy(Proxy value) { proxy = value; }

    public String extension(String original, JSONObject accounts) throws Exception {
        if (accounts == null || original == null || !original.trim().startsWith("{")) return original;
        JSONObject ext = new JSONObject(original);
        boolean configured = false;
        for (String key : List.of("quarkCookie", "ucCookie", "ucToken", "token")) if (!accounts.optString(key).isBlank()) configured = true;
        if (!configured) return original;
        if (ext.has("Cloud-drive")) {
            files.put("accounts", accounts.toString().getBytes(StandardCharsets.UTF_8));
            ext.put("Cloud-drive", base() + "accounts");
        }
        for (var entry : Map.of("cookie", "quarkCookie", "uc_cookie", "ucCookie", "token", "token").entrySet()) {
            String value = accounts.optString(entry.getValue());
            if (ext.has(entry.getKey()) && !value.isBlank()) {
                files.put(entry.getKey(), value.getBytes(StandardCharsets.UTF_8));
                ext.put(entry.getKey(), base() + entry.getKey());
            }
        }
        return ext.toString();
    }
    /** Where the plugin offers the app a sign-in only it has (see syncFtyAccounts). */
    public static final String PLUGIN_ACCOUNTS = "plugin-accounts.json";

    /**
     * FTY keeps its Baidu sign-in in {@code files/mybd_cookie} and its Aliyun one in
     * {@code files/ali_user}, both guard-encrypted JSON ({@code bduss}, {@code stoken}, {@code ptoken};
     * {@code refresh_token}). The app's Baidu account goes in before the spider starts (Aliyun reaches
     * it as the Cloud-drive {@code token}). A sign-in only the plugin has, made through its own QR code
     * before the app kept one, is offered back in the session folder for the app to keep.
     */
    public void syncFtyAccounts(JSONObject accounts, java.nio.file.Path files, java.nio.file.Path folder) {
        var offer = new JSONObject();
        try {
            String cookie = accounts == null ? "" : accounts.optString("baiduCookie");
            var saved = files.resolve("mybd_cookie");
            var fields = new java.util.HashMap<String, String>();
            for (String part : cookie.split(";")) {
                int split = part.indexOf('=');
                if (split > 0) fields.put(part.substring(0, split).trim(), part.substring(split + 1).trim());
            }
            String bduss = fields.getOrDefault("BDUSS", "");
            JSONObject current = readFty(saved);
            if (!bduss.isEmpty()) {
                if (current == null || !bduss.equals(current.optString("bduss"))) {
                    var value = new JSONObject().put("devuid", current == null ? "" : current.optString("devuid"))
                        .put("stoken", fields.getOrDefault("STOKEN", "")).put("bduss", bduss).put("ptoken", fields.getOrDefault("PTOKEN", ""));
                    Files.createDirectories(files);
                    Files.writeString(saved, com.github.catvod.spider.DexNative.encrypt(value.toString()), StandardCharsets.UTF_8);
                    System.err.println("CLOUD_ACCOUNT_RESTORED baidu");
                }
            } else if (current != null && !current.optString("bduss").isEmpty()) {
                var value = new StringBuilder("BDUSS=").append(current.optString("bduss"));
                if (!current.optString("ptoken").isEmpty()) value.append("; PTOKEN=").append(current.optString("ptoken"));
                if (!current.optString("stoken").isEmpty()) value.append("; STOKEN=").append(current.optString("stoken"));
                offer.put("baiduCookie", value.toString());
            }
            if (accounts == null || accounts.optString("token").isBlank()) {
                JSONObject aliyun = readFty(files.resolve("ali_user"));
                String token = aliyun == null ? "" : aliyun.optString("refresh_token");
                if (token.length() == 32) offer.put("token", token);
            }
            var offered = folder.resolve(PLUGIN_ACCOUNTS);
            if (offer.length() > 0) {
                Files.writeString(offered, offer.toString(), StandardCharsets.UTF_8);
                System.err.println("CLOUD_ACCOUNT_OFFERED " + offer.names());
            } else Files.deleteIfExists(offered);
        } catch (Throwable unavailable) {
            System.err.println("CLOUD_ACCOUNT_SYNC_FAILED " + unavailable);
        }
    }

    private static JSONObject readFty(java.nio.file.Path file) {
        try {
            if (!Files.isRegularFile(file)) return null;
            String plain = com.github.catvod.spider.DexNative.decrypt(Files.readString(file, StandardCharsets.UTF_8).trim());
            return plain == null || !plain.trim().startsWith("{") ? null : new JSONObject(plain);
        } catch (Throwable unreadable) { return null; }
    }

    /** Restore the two values FTY normally saves after its Android QR dialog succeeds. */
    public boolean restoreFtyQuarkAccount(JSONObject accounts, Class<?> spiderClass) throws Exception {
        if (accounts == null) return false;
        String cookie = accounts.optString("quarkCookie"), ticket = accounts.optString("quarkServiceTicket");
        if (cookie.isBlank() || ticket.isBlank()) return false;
        Class<?> pan = spiderClass;
        while (pan != null && !pan.getName().equals("com.github.catvod.spider.Pan")) pan = pan.getSuperclass();
        if (pan == null) return false;
        try {
            if (!pan.getField("yq").getType().getName().equals("com.github.catvod.spider.Cloud_quark")) return false;
        } catch (NoSuchFieldException absent) { return false; }
        // Inspected FTY releases rename this helper, while retaining this complete contract.
        // Never alter verification methods or success flags: the plugin validates the cookie.
        for (String name : List.of("xU", "Z")) {
            try {
                Class<?> type = Class.forName("com.github.catvod.spider.merge." + name, false, spiderClass.getClassLoader());
                var singleton = type.getMethod("Zm");
                var web = type.getField("F5"); var mobile = type.getField("W");
                if (singleton.getReturnType() != type || !java.lang.reflect.Modifier.isStatic(singleton.getModifiers())
                    || web.getType() != String.class || mobile.getType() != String.class
                    || type.getField("ee").getType() != String.class
                    || type.getMethod("Gd").getReturnType() != boolean.class
                    || type.getMethod("k", String.class).getReturnType() != boolean.class) continue;
                Object account = singleton.invoke(null);
                web.set(account, cookie); mobile.set(account, ticket);
                System.err.println("CLOUD_ACCOUNT_RESTORED quark");
                return true;
            } catch (ClassNotFoundException | NoSuchFieldException | NoSuchMethodException unsupported) { }
        }
        return false;
    }

    /** The Cloud-based Wogg family accepts inline cookies under different keys than FTY. */
    public String cloudExtension(String original, JSONObject accounts, Class<?> spiderClass) throws Exception {
        if (accounts == null) return original;
        Class<?> cloud = spiderClass;
        while (cloud != null && !cloud.getName().equals("com.github.catvod.spider.Cloud")) cloud = cloud.getSuperclass();
        if (cloud == null) return original;
        // Scope the adapter to the inspected contract; do not send accounts to unrelated spiders.
        try {
            if (!cloud.getField("a").getType().getName().equals("com.github.catvod.spider.Quark")
                || !cloud.getField("c").getType().getName().equals("com.github.catvod.spider.UC")) return original;
        } catch (NoSuchFieldException absent) { return original; }
        JSONObject ext = original == null || original.isBlank() ? new JSONObject() : new JSONObject(original);
        for (var entry : Map.of("cookie", "quarkCookie", "uccookie", "ucCookie", "token", "token").entrySet()) {
            String value = accounts.optString(entry.getValue()).trim();
            if (!value.isEmpty()) ext.put(entry.getKey(), value);
        }
        return ext.toString();
    }

    public String rewriteAddress(String address) {
        for (int port : ports) {
            String prior = "http://127.0.0.1:" + port + "/" + capability + "/";
            if (address.startsWith(prior)) return base() + address.substring(prior.length());
        }
        // Preserve Bili's dedicated progressive-MP4 resolver and plain HLS unwrapping.
        if (address.contains("do=bili") || address.contains("do=m3u8")) return address;
        if (address.matches("^http://(127\\.0\\.0\\.1|localhost)(:-?\\d+)?/proxy\\?.*")) {
            return base() + "media?" + address.substring(address.indexOf('?') + 1);
        }
        return address;
    }
    public String playback(String text) throws Exception {
        ensureAvailable();
        JSONObject result = new JSONObject(text);
        Object value = result.opt("url");
        if (value instanceof String address) result.put("url", rewriteAddress(address));
        else if (value instanceof JSONArray values) for (int i = 1; i < values.length(); i += 2) {
            Object item = values.get(i); if (item instanceof String address) values.put(i, rewriteAddress(address));
        }
        return result.toString();
    }
    /** Sources sharing one plugin runtime each keep a bridge; the running request selects its own. */
    public void activate() { current = this; active.set(this); }
    public static void deactivate() { active.remove(); }
    public static void closeCurrent() { if (current != null) current.close(); }
    @Override public synchronized void close() { closed = true; server.stop(0); workers.shutdownNow(); if (current == this) current = null; }
}
