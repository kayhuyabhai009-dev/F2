// Minimal CLI driver around the modern jadx-core API (jadx.jar).
// Compile:  javac -cp /opt/tools/jadx/jadx-core-modern.jar JadxRunner.java
// Run:      java -cp .:/opt/tools/jadx/jadx-core-modern.jar JadxRunner <input> <outdir> [nores]
//
// Why: this sandbox can reach only GitHub source archives, PyPI and npm.
// The official jadx release zip lives on GitHub *release assets* (blocked), but
// the `jadx-mcp` npm package bundles a recent shaded jadx-core, so we drive its
// public API (jadx.api.JadxDecompiler) instead.
import jadx.api.JadxArgs;
import jadx.api.JadxDecompiler;

import java.io.File;

public class JadxRunner {
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: JadxRunner <input.apk|input.dex> <outdir> [nores]");
            System.exit(2);
        }
        JadxArgs jadxArgs = new JadxArgs();
        jadxArgs.getInputFiles().add(new File(args[0]));
        jadxArgs.setOutDir(new File(args[1]));
        if (args.length > 2 && args[2].equalsIgnoreCase("nores")) {
            jadxArgs.setSkipResources(true);
        }
        jadxArgs.setThreadsCount(Math.max(1, Runtime.getRuntime().availableProcessors()));
        try (JadxDecompiler decompiler = new JadxDecompiler(jadxArgs)) {
            decompiler.load();
            decompiler.save();
        }
        System.out.println("JADX_DONE -> " + args[1]);
    }
}
