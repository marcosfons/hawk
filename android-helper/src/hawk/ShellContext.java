package hawk;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;
import android.os.Looper;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** A context for a bare app_process run as the shell user. */
final class ShellContext {
    static final String SHELL = "com.android.shell";
    static final int SHELL_UID = 2000;

    static Context create() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Constructor<?> c = at.getDeclaredConstructor();
        c.setAccessible(true);
        Object thread = c.newInstance();
        Field current = at.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        // Vendor frameworks (Samsung's) reach for the bound application and the
        // configuration controller of the current ActivityThread; a bare one has neither.
        try {
            Class<?> abd = Class.forName("android.app.ActivityThread$AppBindData");
            Constructor<?> abdc = abd.getDeclaredConstructor();
            abdc.setAccessible(true);
            Object data = abdc.newInstance();
            ApplicationInfo ai = new ApplicationInfo();
            ai.packageName = SHELL;
            Field appInfo = abd.getDeclaredField("appInfo");
            appInfo.setAccessible(true);
            appInfo.set(data, ai);
            Field bound = at.getDeclaredField("mBoundApplication");
            bound.setAccessible(true);
            bound.set(thread, data);
        } catch (Throwable ignored) {
            // Not every framework has it; AOSP works without.
        }
        try {
            Class<?> ccc = Class.forName("android.app.ConfigurationController");
            Class<?> ati = Class.forName("android.app.ActivityThreadInternal");
            Constructor<?> cc = ccc.getDeclaredConstructor(ati);
            cc.setAccessible(true);
            Object controller = cc.newInstance(thread);
            Field field = at.getDeclaredField("mConfigurationController");
            field.setAccessible(true);
            field.set(thread, controller);
        } catch (Throwable ignored) {
            // Older frameworks have no ConfigurationController.
        }
        Method systemContext = at.getDeclaredMethod("getSystemContext");
        Context sys = (Context) systemContext.invoke(thread);
        return new ContextWrapper(sys) {
            @Override public String getPackageName() { return SHELL; }
            @Override public String getOpPackageName() { return SHELL; }
            @Override public AttributionSource getAttributionSource() {
                return new AttributionSource.Builder(SHELL_UID).setPackageName(SHELL).build();
            }
            @Override public Context getApplicationContext() { return this; }
        };
    }
}
