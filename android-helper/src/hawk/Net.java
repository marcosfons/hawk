package hawk;

import android.app.usage.NetworkStats;
import android.app.usage.NetworkStatsManager;
import android.content.Context;
import android.net.ConnectivityManager;
import android.os.IBinder;

import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.util.HashMap;
import java.util.Map;

/** Per-UID data per time window, about 100 days back (dumpsys only has 24 hours). */
final class Net {
    static void history(Context context, PrintStream out, long from, long to, long step) throws Exception {
        if (step < 3_600_000L || to <= from || (to - from) / step > 400) throw new IllegalArgumentException("windows");
        NetworkStatsManager nsm = manager(context);
        int[] types = {ConnectivityManager.TYPE_WIFI, ConnectivityManager.TYPE_MOBILE};
        NetworkStats.Bucket b = new NetworkStats.Bucket();
        for (long start = from; start < to; start += step) {
            long end = Math.min(start + step, to);
            for (int type : types) {
                Map<String, long[]> totals = new HashMap<>();
                NetworkStats s = nsm.querySummary(type, null, start, end);
                while (s.hasNextBucket()) {
                    s.getNextBucket(b);
                    String key = b.getUid() + "\t" + (b.getState() == NetworkStats.Bucket.STATE_FOREGROUND ? "fg" : "bg");
                    long[] v = totals.get(key);
                    if (v == null) totals.put(key, v = new long[2]);
                    v[0] += b.getRxBytes();
                    v[1] += b.getTxBytes();
                }
                s.close();
                String kind = type == ConnectivityManager.TYPE_WIFI ? "w" : "m";
                for (Map.Entry<String, long[]> e : totals.entrySet()) {
                    out.println("N\t" + kind + "\t" + start + "\t" + e.getKey() + "\t" + e.getValue()[0] + "\t" + e.getValue()[1]);
                }
            }
        }
    }

    /** The system's own manager belongs to the "android" package and is refused; this one is the shell's. */
    static NetworkStatsManager manager(Context context) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object binder = sm.getMethod("getService", String.class).invoke(null, "netstats");
        Class<?> stub = Class.forName("android.net.INetworkStatsService$Stub");
        Object service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
        Constructor<NetworkStatsManager> c = NetworkStatsManager.class.getDeclaredConstructor(
                Context.class, Class.forName("android.net.INetworkStatsService"));
        c.setAccessible(true);
        return c.newInstance(context, service);
    }
}
