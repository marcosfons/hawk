package hawk;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.util.List;

/** Labels and small PNG icons for the packages asked for. */
final class Icons {
    static void draw(Context context, PrintStream out, int px, List<String> packages) {
        if (px < 8 || px > 128) throw new IllegalArgumentException("icon size");
        PackageManager pm = context.getPackageManager();
        Bitmap bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        ByteArrayOutputStream png = new ByteArrayOutputStream(8192);
        int done = 0;
        for (String name : packages) {
            try {
                PackageInfo p = pm.getPackageInfo(name, 0);
                ApplicationInfo ai = p.applicationInfo;
                if (ai == null) continue;
                // Memory stays near 45 MB instead of growing to hundreds on a first pass.
                if (++done % 25 == 0) System.gc();
                String label = Text.clean(ai.loadLabel(pm).toString());
                String icon = "";
                if (ai.icon != 0) {
                    // The raw icon resource, not loadIcon: vendor "live" icons (a calendar
                    // drawing the date) need fonts this bare process never loads.
                    Drawable d = pm.getDrawable(name, ai.icon, ai);
                    if (d != null) {
                        bitmap.eraseColor(0);
                        d.setBounds(0, 0, px, px);
                        d.draw(canvas);
                        png.reset();
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
                        icon = Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
                    }
                }
                out.print("I\t"); out.print(name); out.print('\t'); out.print(p.getLongVersionCode()); out.print('\t');
                out.print(label); out.print('\t'); out.println(icon);
            } catch (Throwable t) {
                out.println("E\ticons\t" + name + ": " + Text.clean(t.toString()));
            }
        }
    }
}
