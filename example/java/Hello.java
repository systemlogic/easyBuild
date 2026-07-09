public final class Hello {


        public static void main(String[] args) {
        System.out.println("Hello from a hermetic Bazel + remote JDK toolchain!");
        System.out.println("OS:        " + System.getProperty("os.name"));
        System.out.println("Arch:      " + System.getProperty("os.arch"));
        System.out.println("Java:      " + System.getProperty("java.version"));
        // java.home must point under Bazel's execroot/external tree, not a
        // system JDK install (e.g. /Library/Java/... or /usr/lib/jvm/...).
        System.out.println("java.home: " + System.getProperty("java.home"));
    }
}
