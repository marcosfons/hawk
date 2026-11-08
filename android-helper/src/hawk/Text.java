package hawk;

/** Values put in output fields: one line, no tabs, bounded. */
final class Text {
    static String clean(String s) {
        String t = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
        return t.length() > 200 ? t.substring(0, 200) : t;
    }
}
