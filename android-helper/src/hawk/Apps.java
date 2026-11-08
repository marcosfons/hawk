package hawk;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;

import java.io.PrintStream;

/** Every package's metadata: no labels or icons, which need each app's resources. */
final class Apps {
    static void list(Context context, PrintStream out) {
        PackageManager pm = context.getPackageManager();
        for (PackageInfo p : pm.getInstalledPackages(0)) {
            ApplicationInfo ai = p.applicationInfo;
            if (ai == null) continue;
            String installer = "";
            try {
                String name = pm.getInstallSourceInfo(p.packageName).getInstallingPackageName();
                if (name != null) installer = name;
            } catch (Throwable ignored) {
                // Some packages have no install source; the column stays empty.
            }
            out.print("A\t");
            out.print(p.packageName); out.print('\t');
            out.print(p.getLongVersionCode()); out.print('\t');
            out.print(Text.clean(p.versionName == null ? "" : p.versionName)); out.print('\t');
            out.print((ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0 ? 1 : 0); out.print('\t');
            out.print(ai.enabled ? 1 : 0); out.print('\t');
            out.print(p.firstInstallTime); out.print('\t');
            out.print(p.lastUpdateTime); out.print('\t');
            out.print(ai.targetSdkVersion); out.print('\t');
            out.println(installer);
        }
    }
}
