package hawk;

import android.content.Context;
import android.os.Process;
import android.os.SystemClock;

import java.io.BufferedOutputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Hawk's on-device helper, run by the shell user with app_process, like scrcpy's
 * server. Not an app: nothing installed, no permission prompt; it does the work it
 * was given and exits.
 *
 * Commands, separated by "--", all in one run:
 *   apps                          every package's metadata
 *   icons <px> <package>...       label and PNG icon of these packages
 *   net <from> <to> <step>        per-UID data per window, Wi-Fi and mobile (ms)
 *
 * Output, one record per line, tab-separated, first field the kind:
 *   A pkg versionCode versionName system enabled firstInstall lastUpdate targetSdk installer
 *   I pkg versionCode label base64png
 *   N w|m windowStart uid fg|bg rx tx
 *   E command message
 *   S cpu_ms=.. wall_ms=.. pss_kb=.. hwm_kb=..
 *   D                             (last line: the run completed)
 */
public final class Helper {
    public static void main(String[] args) {
        long started = SystemClock.uptimeMillis();
        PrintStream out = new PrintStream(new BufferedOutputStream(new FileOutputStream(FileDescriptor.out), 1 << 16), false);
        Context context = null;
        for (List<String> command : split(args)) {
            String name = command.get(0);
            try {
                if (context == null) context = ShellContext.create();
                switch (name) {
                    case "apps": Apps.list(context, out); break;
                    case "icons": Icons.draw(context, out, Integer.parseInt(command.get(1)), command.subList(2, command.size())); break;
                    case "net": Net.history(context, out, Long.parseLong(command.get(1)), Long.parseLong(command.get(2)), Long.parseLong(command.get(3))); break;
                    default: out.println("E\t" + name + "\tunknown command");
                }
            } catch (Throwable t) {
                out.println("E\t" + name + "\t" + Text.clean(t.toString()));
            }
            out.flush();
        }
        out.println("S\tcpu_ms=" + Process.getElapsedCpuTime() + "\twall_ms=" + (SystemClock.uptimeMillis() - started) + "\t" + Mem.summary());
        out.println("D");
        out.flush();
        // Framework threads would otherwise keep the process alive.
        System.exit(0);
    }

    static List<List<String>> split(String[] args) {
        List<List<String>> out = new ArrayList<>();
        List<String> current = new ArrayList<>();
        for (String a : args) {
            if (a.equals("--")) {
                if (!current.isEmpty()) out.add(current);
                current = new ArrayList<>();
            } else {
                current.add(a);
            }
        }
        if (!current.isEmpty()) out.add(current);
        if (out.isEmpty()) out.add(Arrays.asList("apps"));
        return out;
    }
}
