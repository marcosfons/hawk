package hawk;

import android.app.usage.NetworkStats;
import android.app.usage.NetworkStatsManager;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.ConnectivityManager;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Base64;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.FileReader;
import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Prototype: run with app_process as the shell user. */
public final class Agent {
    static final PrintStream out = new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), false);

    static Context context() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> c = at.getDeclaredConstructor();
        c.setAccessible(true);
        Object thread = c.newInstance();
        Field cur = at.getDeclaredField("sCurrentActivityThread");
        cur.setAccessible(true);
        cur.set(null, thread);
        // Vendor code (Samsung) reaches for the bound app and configuration of
        // the current ActivityThread; a bare one has neither.
        try {
            Class<?> abd = Class.forName("android.app.ActivityThread$AppBindData");
            Constructor<?> abdc = abd.getDeclaredConstructor();
            abdc.setAccessible(true);
            Object data = abdc.newInstance();
            ApplicationInfo ai = new ApplicationInfo();
            ai.packageName = "com.android.shell";
            Field aif = abd.getDeclaredField("appInfo");
            aif.setAccessible(true);
            aif.set(data, ai);
            Field mba = at.getDeclaredField("mBoundApplication");
            mba.setAccessible(true);
            mba.set(thread, data);
        } catch (Throwable t) { System.err.println("warn bound app: " + t); }
        try {
            Class<?> ccc = Class.forName("android.app.ConfigurationController");
            Class<?> ati = Class.forName("android.app.ActivityThreadInternal");
            Constructor<?> cc = ccc.getDeclaredConstructor(ati);
            cc.setAccessible(true);
            Object controller = cc.newInstance(thread);
            Field mcc = at.getDeclaredField("mConfigurationController");
            mcc.setAccessible(true);
            mcc.set(thread, controller);
        } catch (Throwable t) { System.err.println("warn config controller: " + t); }
        Method gsc = at.getDeclaredMethod("getSystemContext");
        Context sys = (Context) gsc.invoke(thread);
        return new ContextWrapper(sys) {
            @Override public String getPackageName() { return "com.android.shell"; }
            @Override public String getOpPackageName() { return "com.android.shell"; }
            @Override public AttributionSource getAttributionSource() {
                return new AttributionSource.Builder(2000).setPackageName("com.android.shell").build();
            }
            @Override public Context getApplicationContext() { return this; }
        };
    }

    public static void main(String[] args) throws Exception {
        long t0 = SystemClock.uptimeMillis();
        String cmd = args.length > 0 ? args[0] : "noop";
        if (cmd.equals("bare")) { System.err.println("stats cpu_ms=" + Process.getElapsedCpuTime() + " " + mem()); return; }
        Context ctx = context();
        long tCtx = SystemClock.uptimeMillis();
        switch (cmd) {
            case "net-depth": netDepth(ctx); break;
            case "net": net(ctx, Integer.parseInt(args[1])); break;
            case "icons": icons(ctx, Integer.parseInt(args[1]), args.length > 2 ? Integer.parseInt(args[2]) : 0, args.length > 3 ? Integer.parseInt(args[3]) : 100000, false); break;
            case "icons-user": icons(ctx, Integer.parseInt(args[1]), 0, 100000, true); break;
            default: break;
        }
        out.flush();
        long t1 = SystemClock.uptimeMillis();
        System.err.println("stats ctx_ms=" + (tCtx - t0) + " work_ms=" + (t1 - tCtx)
                + " cpu_ms=" + Process.getElapsedCpuTime() + " " + mem());
    }

    /** The system's own manager is bound to the "android" package; build one bound to the shell package. */
    static NetworkStatsManager netstats(Context ctx) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object binder = sm.getMethod("getService", String.class).invoke(null, "netstats");
        Class<?> stub = Class.forName("android.net.INetworkStatsService$Stub");
        Object svc = stub.getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
        Constructor<NetworkStatsManager> c = NetworkStatsManager.class.getDeclaredConstructor(Context.class, Class.forName("android.net.INetworkStatsService"));
        c.setAccessible(true);
        return c.newInstance(ctx, svc);
    }

    static String mem() throws Exception {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/smaps_rollup"))) {
            String l;
            while ((l = r.readLine()) != null)
                if (l.startsWith("Pss:") || l.startsWith("Private_Dirty") || l.startsWith("Private_Clean")) sb.append(l.replaceAll("\\s+", "")).append(' ');
        } catch (Exception e) { sb.append("smaps_rollup:").append(e.getMessage()).append(' '); }
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/status"))) {
            String l;
            while ((l = r.readLine()) != null)
                if (l.startsWith("VmHWM") || l.startsWith("VmRSS")) sb.append(l.replaceAll("\\s+", "")).append(' ');
        }
        return sb.toString();
    }

    /** Total bytes per 30-day window going back, per transport: shows how far history reaches. */
    static void netDepth(Context ctx) throws Exception {
        NetworkStatsManager nsm = netstats(ctx);
        long now = System.currentTimeMillis(), day = 86_400_000L;
        int[] types = {ConnectivityManager.TYPE_WIFI, ConnectivityManager.TYPE_MOBILE};
        for (int type : types) {
            for (int w = 0; w < 12; w++) {
                long end = now - w * 15 * day, start = end - 15 * day;
                long bytes = 0; int uids = 0;
                NetworkStats s = nsm.querySummary(type, null, start, end);
                NetworkStats.Bucket b = new NetworkStats.Bucket();
                java.util.HashSet<Integer> seen = new java.util.HashSet<>();
                while (s.hasNextBucket()) { s.getNextBucket(b); bytes += b.getRxBytes() + b.getTxBytes(); seen.add(b.getUid()); }
                s.close();
                out.println((type == ConnectivityManager.TYPE_WIFI ? "wifi" : "mobile") + " days_ago=" + (w * 15) + "-" + ((w + 1) * 15)
                        + " MB=" + (bytes >> 20) + " uids=" + seen.size());
            }
        }
    }

    /** Per-UID rx/tx for the last N days, wifi and mobile, foreground/background. */
    static void net(Context ctx, int days) throws Exception {
        NetworkStatsManager nsm = netstats(ctx);
        long end = System.currentTimeMillis(), start = end - days * 86_400_000L;
        int[] types = {ConnectivityManager.TYPE_WIFI, ConnectivityManager.TYPE_MOBILE};
        int lines = 0;
        for (int type : types) {
            NetworkStats s = nsm.querySummary(type, null, start, end);
            NetworkStats.Bucket b = new NetworkStats.Bucket();
            Map<String, long[]> agg = new HashMap<>();
            while (s.hasNextBucket()) {
                s.getNextBucket(b);
                String k = b.getUid() + (b.getState() == NetworkStats.Bucket.STATE_FOREGROUND ? " fg" : " bg");
                long[] v = agg.computeIfAbsent(k, x -> new long[2]);
                v[0] += b.getRxBytes(); v[1] += b.getTxBytes();
            }
            s.close();
            for (Map.Entry<String, long[]> e : agg.entrySet()) {
                out.println((type == ConnectivityManager.TYPE_WIFI ? "w " : "m ") + e.getKey() + " " + e.getValue()[0] + " " + e.getValue()[1]);
                lines++;
            }
        }
        System.err.println("net lines=" + lines);
    }

    /** package \t versionCode \t label \t base64 PNG, one line per app. */
    static void icons(Context ctx, int px, int from, int count, boolean userOnly) throws Exception {
        PackageManager pm = ctx.getPackageManager();
        List<PackageInfo> pkgs = pm.getInstalledPackages(0);
        Bitmap bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bmp);
        ByteArrayOutputStream png = new ByteArrayOutputStream(8192);
        long bytes = 0;
        int i = -1, done = 0;
        for (PackageInfo p : pkgs) {
            i++;
            if (i < from || i >= from + count) continue;
            ApplicationInfo ai = p.applicationInfo;
            if (ai == null || ai.icon == 0) continue;
            if (userOnly && (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0) continue;
            if (++done % 25 == 0) System.gc();
            CharSequence label = ai.loadLabel(pm);
            // The raw icon resource: skips vendor "live" icons (Samsung's calendar draws
            // text, which needs fonts this bare process never loaded).
            Drawable d = ai.icon != 0 ? pm.getDrawable(p.packageName, ai.icon, ai) : null;
            if (d == null) d = pm.getDefaultActivityIcon();
            bmp.eraseColor(0);
            d.setBounds(0, 0, px, px);
            d.draw(canvas);
            png.reset();
            bmp.compress(Bitmap.CompressFormat.PNG, 100, png);
            bytes += png.size();
            out.print(p.packageName); out.print('\t'); out.print(p.getLongVersionCode()); out.print('\t');
            out.print(label.toString().replace('\t', ' ').replace('\n', ' ')); out.print('\t');
            out.println(Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP));
        }
        System.err.println("icons total=" + pkgs.size() + " drawn=" + done + " png_kb=" + (bytes >> 10));
    }
}
