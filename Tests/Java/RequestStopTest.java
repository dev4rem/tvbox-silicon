import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONObject;
import tvbox.runtime.HttpDiagnostics;
import tvbox.runtime.PluginSession;

/**
 * Plugins wait for an Android QR sign-in, or a result, in polling loops that never end on this host.
 * A request the app abandons, or one past its deadline, must stop at the next wait, even through
 * the catch (Exception) blocks those loops are wrapped in.
 */
public final class RequestStopTest {
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

    public static void main(String[] args) throws Exception {
        // A long sleep ends soon after the app gives up on the request.
        AtomicLong stop = new AtomicLong();
        HttpDiagnostics.beginRequest(false, stop, null);
        new Thread(() -> { sleep(300); stop.set(System.currentTimeMillis()); }).start();
        long started = System.nanoTime();
        Throwable thrown = null;
        try { android.os.SystemClock.sleep(10_000); } catch (Throwable error) { thrown = error; }
        long waited = (System.nanoTime() - started) / 1_000_000;
        check(thrown instanceof HttpDiagnostics.RequestStopped, "Abandoned sleep did not stop: " + thrown);
        check(waited < 1500, "Abandoned sleep took " + waited + " ms to stop");
        HttpDiagnostics.endRequest();

        // Outside a request, sleeping is just sleeping.
        android.os.SystemClock.sleep(20);

        // A spider polling forever behind catch (Exception) ends at its deadline.
        var session = new PluginSession(new PollingSpider());
        started = System.nanoTime();
        thrown = null;
        try { session.request(new JSONObject().put("play", "x").put("flag", "line").put("_deadline", 1)); }
        catch (Throwable error) { thrown = error; }
        waited = (System.nanoTime() - started) / 1_000_000;
        check(thrown instanceof HttpDiagnostics.RequestStopped, "Polling spider was not stopped: " + thrown);
        check(waited >= 900 && waited < 2500, "Deadline of 1 s stopped after " + waited + " ms");
        var envelope = tvbox.runtime.NativeProbe.failure(thrown);
        check("source_timeout".equals(envelope.optString("errorCode")), "Stop was not reported as a timeout: " + envelope);

        // A request without a deadline or cancel is never stopped by the host.
        var quick = new PluginSession(new QuickSpider());
        check(quick.request(new JSONObject().put("ids", "1")).contains("vod_id"), "Unstopped request failed");

        // Android QR sign-ins the host cannot show are handed back to the app.
        Method drive = HttpDiagnostics.class.getDeclaredMethod("qrLoginDrive", String.class, String.class);
        drive.setAccessible(true);
        check("quark".equals(drive.invoke(null, "uop.quark.cn", "/cas/ajax/getTokenForQrcodeLogin")), "Quark QR");
        check("uc".equals(drive.invoke(null, "api.open.uc.cn", "/cas/ajax/getServiceTicketByQrcodeToken")), "UC QR");
        check("baidu".equals(drive.invoke(null, "passport.baidu.com", "/v2/api/getqrcode")), "Baidu QR");
        check("baidu".equals(drive.invoke(null, "passport.baidu.com", "/channel/unicast")), "Baidu QR poll");
        check("aliyun".equals(drive.invoke(null, "passport.aliyundrive.com", "/newlogin/qrcode/query.do")), "Aliyun QR poll");
        check("aliyun".equals(drive.invoke(null, "openapi.aliyundrive.com", "/oauth/qrcode/abc")), "Aliyun open QR");
        check(drive.invoke(null, "pan.baidu.com", "/share/list") == null, "A Baidu share listing is not a sign-in");
        check(drive.invoke(null, "api.aliyundrive.com", "/adrive/v3/file/list") == null, "An Aliyun file listing is not a sign-in");
        signInCodes();
        System.out.println("RequestStopTest passed: abandoned sleeps stop, deadlines stop polling spiders, QR sign-ins hand back, Baidu/Aliyun codes reach the app");
    }

    /** Baidu and Aliyun sign-ins stay in the plugin: their codes go to the app, and scanning gets time. */
    private static void signInCodes() throws Exception {
        var folder = java.nio.file.Files.createTempDirectory("sign-in");
        Class<?> prompt = Class.forName("tvbox.runtime.LoginPrompt");
        Method capture = prompt.getDeclaredMethod("capture", String.class, okhttp3.Response.class, java.nio.file.Path.class);
        capture.setAccessible(true);
        var baidu = (okhttp3.Response) capture.invoke(null, "baidu", response("https://passport.baidu.com/v2/api/getqrcode?lp=pc",
            "tangram_guid_1({\"imgurl\":\"passport.baidu.com/v2/api/qrcode?sign=abc&lp=pc\",\"sign\":\"abc\"})"), folder);
        check(baidu != null && baidu.body().string().contains("\"sign\":\"abc\""), "The plugin lost its own QR response");
        var code = new JSONObject(java.nio.file.Files.readString(folder.resolve("login-prompt.json")));
        check("baidu".equals(code.getString("drive")) && "https://passport.baidu.com/v2/api/qrcode?sign=abc&lp=pc".equals(code.getString("image")), "Baidu code: " + code);
        var aliyun = (okhttp3.Response) capture.invoke(null, "aliyun", response("https://passport.aliyundrive.com/newlogin/qrcode/generate.do",
            "{\"content\":{\"data\":{\"t\":1,\"ck\":\"x\",\"codeContent\":\"https://passport.aliyundrive.com/qrcodeCheck.htm?lgToken=t\"}}}"), folder);
        check(aliyun != null, "Aliyun response dropped");
        code = new JSONObject(java.nio.file.Files.readString(folder.resolve("login-prompt.json")));
        check("aliyun".equals(code.getString("drive")) && code.getString("content").contains("lgToken=t"), "Aliyun code: " + code);
        // A response without a code hands the sign-in back to the app instead of waiting on nothing.
        check(capture.invoke(null, "baidu", response("https://passport.baidu.com/v2/api/getqrcode", "oops"), folder) == null, "Codeless response was kept");

        Method extend = HttpDiagnostics.class.getDeclaredMethod("extendForSignIn");
        extend.setAccessible(true);
        long now = System.currentTimeMillis();
        AtomicLong running = new AtomicLong(now + 5_000);
        HttpDiagnostics.beginRequest(true, running, folder.toString());
        extend.invoke(null);
        check(running.get() >= now + 170_000, "Scanning got no time: " + (running.get() - now));
        AtomicLong cancelled = new AtomicLong(now - 1);
        HttpDiagnostics.beginRequest(true, cancelled, folder.toString());
        extend.invoke(null);
        check(cancelled.get() == now - 1, "A cancelled request came back to life");
        HttpDiagnostics.endRequest();

        // The sign-in completes: Baidu sets BDUSS, Aliyun reports CONFIRMED.
        Method confirming = prompt.getDeclaredMethod("confirmingDrive", String.class, String.class); confirming.setAccessible(true);
        check("baidu".equals(confirming.invoke(null, "passport.baidu.com", "/v3/login/main/qrbdusslogin")), "Baidu confirmation");
        check("aliyun".equals(confirming.invoke(null, "passport.aliyundrive.com", "/newlogin/qrcode/query.do")), "Aliyun confirmation");
        Method confirms = prompt.getDeclaredMethod("confirms", String.class, String.class, okhttp3.Response.class); confirms.setAccessible(true);
        var cookie = response("https://passport.baidu.com/v3/login/main/qrbdusslogin", "bd__cbs__1({})").newBuilder()
            .addHeader("Set-Cookie", "BDUSS=abc; domain=.baidu.com").build();
        check((Boolean) confirms.invoke(null, "baidu", "/v3/login/main/qrbdusslogin", cookie), "BDUSS cookie not seen as a sign-in");
        check(!(Boolean) confirms.invoke(null, "baidu", "/v3/login/main/qrbdusslogin", response("https://passport.baidu.com/v3/login/main/qrbdusslogin", "x")), "No cookie, no sign-in");
        var confirmed = response("https://passport.aliyundrive.com/newlogin/qrcode/query.do", "{\"content\":{\"data\":{\"qrCodeStatus\":\"CONFIRMED\"}}}");
        check((Boolean) confirms.invoke(null, "aliyun", "/newlogin/qrcode/query.do", confirmed), "Aliyun CONFIRMED not seen");
        check(confirmed.body().string().contains("CONFIRMED"), "Checking consumed the plugin's response");
        check(!(Boolean) confirms.invoke(null, "aliyun", "/newlogin/qrcode/query.do",
            response("https://passport.aliyundrive.com/newlogin/qrcode/query.do", "{\"content\":{\"data\":{\"qrCodeStatus\":\"NEW\"}}}")), "NEW is not a sign-in");

        // The account the confirmation carries goes to the app: Baidu's cookies, Aliyun's refresh token.
        Method account = prompt.getDeclaredMethod("account", String.class, okhttp3.Response.class); account.setAccessible(true);
        var baiduLogin = response("https://passport.baidu.com/v3/login/main/qrbdusslogin", "x").newBuilder()
            .addHeader("Set-Cookie", "BDUSS=bd; domain=.baidu.com").addHeader("Set-Cookie", "STOKEN=st; domain=passport.baidu.com")
            .addHeader("Set-Cookie", "PTOKEN=pt; domain=passport.baidu.com").addHeader("Set-Cookie", "UBI=ignored").build();
        check(java.util.Map.of("baiduCookie", "BDUSS=bd; PTOKEN=pt; STOKEN=st").equals(account.invoke(null, "baidu", baiduLogin)), "Baidu account: " + account.invoke(null, "baidu", baiduLogin));
        String bizExt = java.util.Base64.getEncoder().encodeToString("{\"pds_login_result\":{\"nickName\":\"ä¸­\",\"refreshToken\":\"0123456789abcdef0123456789abcdef\"}}".getBytes(java.nio.charset.StandardCharsets.ISO_8859_1));
        var aliyunLogin = response("https://passport.aliyundrive.com/newlogin/qrcode/query.do", "{\"content\":{\"data\":{\"qrCodeStatus\":\"CONFIRMED\",\"bizExt\":\"" + bizExt + "\"}}}");
        check(java.util.Map.of("token", "0123456789abcdef0123456789abcdef").equals(account.invoke(null, "aliyun", aliyunLogin)), "Aliyun account: " + account.invoke(null, "aliyun", aliyunLogin));

        // After it, the waiting spider ends shortly (the plugin has saved the account) and the app hears it.
        var session = new PluginSession(new SigningInSpider());
        long started = System.nanoTime();
        Throwable thrown = null;
        try { session.request(new JSONObject().put("play", "x").put("flag", "line").put("_folder", folder.toString())); }
        catch (Throwable error) { thrown = error; }
        long waited = (System.nanoTime() - started) / 1_000_000;
        check(thrown instanceof HttpDiagnostics.SignedIn, "The waiting spider did not end after the sign-in: " + thrown);
        check(waited >= 1400 && waited < 3000, "Ended after " + waited + " ms");
        var notice = new JSONObject(java.nio.file.Files.readString(folder.resolve("login-prompt.json")));
        check(notice.optBoolean("signedIn") && "BDUSS=bd".equals(notice.optString("baiduCookie")), "The app was not told: " + notice);
    }

    /** Signs in (as the host sees Baidu's BDUSS login), then keeps waiting like FTY's dialog-bound loop. */
    public static final class SigningInSpider extends com.github.catvod.crawler.Spider {
        @Override public String playerContent(String flag, String id, List<String> flags) throws Exception {
            Method signedIn = HttpDiagnostics.class.getDeclaredMethod("signedIn", String.class, java.nio.file.Path.class, okhttp3.Response.class);
            signedIn.setAccessible(true);
            Method folder = HttpDiagnostics.class.getDeclaredMethod("promptFolder"); folder.setAccessible(true);
            signedIn.invoke(null, "baidu", folder.invoke(null), response("https://passport.baidu.com/v3/login/main/qrbdusslogin", "x").newBuilder()
                .addHeader("Set-Cookie", "BDUSS=bd").build());
            while (true) {
                try { android.os.SystemClock.sleep(500); } catch (Exception ignored) { }
            }
        }
    }

    private static okhttp3.Response response(String url, String body) {
        return new okhttp3.Response.Builder().request(new okhttp3.Request.Builder().url(url).build())
            .protocol(okhttp3.Protocol.HTTP_1_1).code(200).message("OK")
            .body(okhttp3.ResponseBody.create(body, okhttp3.MediaType.get("text/javascript"))).build();
    }

    private static void sleep(long millis) { try { Thread.sleep(millis); } catch (InterruptedException ignored) { } }

    /** Waits for a sign-in nobody can give, swallowing every Exception as FTY's drive classes do. */
    public static final class PollingSpider extends com.github.catvod.crawler.Spider {
        @Override public String detailContent(List<String> ids) { return "{\"list\":[{\"vod_id\":\"x\"}]}"; }
        @Override public String playerContent(String flag, String id, List<String> flags) {
            while (true) {
                try { android.os.SystemClock.sleep(500); } catch (Exception ignored) { }
            }
        }
    }

    public static final class QuickSpider extends com.github.catvod.crawler.Spider {
        @Override public String detailContent(List<String> ids) { return "{\"list\":[{\"vod_id\":\"1\"}]}"; }
    }
}
