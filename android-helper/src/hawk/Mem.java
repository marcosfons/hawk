package hawk;

import java.io.BufferedReader;
import java.io.FileReader;

/** This process's memory, for Hawk's measurements: PSS and peak resident. */
final class Mem {
    static String summary() {
        String pss = "?", hwm = "?";
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/smaps_rollup"))) {
            for (String l; (l = r.readLine()) != null; ) if (l.startsWith("Pss:")) pss = l.replaceAll("[^0-9]", "");
        } catch (Exception ignored) {
            // Not readable on every kernel; the field says "?".
        }
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/status"))) {
            for (String l; (l = r.readLine()) != null; ) if (l.startsWith("VmHWM")) hwm = l.replaceAll("[^0-9]", "");
        } catch (Exception ignored) {
            // Same.
        }
        return "pss_kb=" + pss + "\thwm_kb=" + hwm;
    }
}
