import alice.tuprolog.Prolog;
import alice.tuprolog.SolveInfo;
import alice.tuprolog.Theory;
import alice.tuprolog.Term;
import alice.tuprolog.Var;
import alice.tuprolog.event.ExceptionEvent;
import alice.tuprolog.event.OutputEvent;
import alice.tuprolog.event.SpyEvent;
import alice.tuprolog.event.WarningEvent;
import alice.tuprolog.interfaces.event.ExceptionListener;
import alice.tuprolog.interfaces.event.OutputListener;
import alice.tuprolog.interfaces.event.SpyListener;
import alice.tuprolog.interfaces.event.WarningListener;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

public class TuPrologRepl {
    private static final String END = "<<<END>>>";

    private static Prolog engine;
    private static SolveInfo lastSolve;
    private static final Object outLock = new Object();

    public static void main(String[] args) throws Exception {
        engine = new Prolog();
        engine.addOutputListener(new OutputListener() {
            @Override public void onOutput(OutputEvent e) {
                synchronized (outLock) { System.out.print(e.getMsg()); System.out.flush(); }
            }
        });
        engine.addExceptionListener(new ExceptionListener() {
            @Override public void onException(ExceptionEvent e) {
                emit("ERROR: " + e.getMsg());
            }
        });
        engine.addWarningListener(new WarningListener() {
            @Override public void onWarning(WarningEvent e) {
                emit("WARN: " + e.getMsg());
            }
        });
        engine.addSpyListener(new SpyListener() {
            @Override public void onSpy(SpyEvent e) {
                emit("[trace] " + e.getMsg());
            }
        });

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));

        emit("tuProlog REPL ready.");
        endBlock();

        StringBuilder buf = new StringBuilder();
        String line;
        while ((line = in.readLine()) != null) {
            String trimmed = line.trim();
            if (buf.length() == 0 && trimmed.startsWith(":")) {
                handleMeta(trimmed);
                endBlock();
                continue;
            }
            if (buf.length() > 0) buf.append('\n');
            buf.append(line);
            String s = buf.toString().replaceAll("\\s+$", "");
            if (s.endsWith(".")) {
                runQuery(s);
                buf.setLength(0);
                endBlock();
            }
        }
    }

    private static void handleMeta(String cmd) {
        try {
            if (cmd.equals(":next")) {
                if (lastSolve != null && lastSolve.hasOpenAlternatives()) {
                    lastSolve = engine.solveNext();
                    printSolve(lastSolve);
                } else {
                    emit("No (more) solutions.");
                }
            } else if (cmd.equals(":stop")) {
                if (lastSolve != null) {
                    try { engine.solveHalt(); } catch (Throwable ignored) {}
                    try { engine.solveEnd(); } catch (Throwable ignored) {}
                    emit("halted.");
                    lastSolve = null;
                }
            } else if (cmd.startsWith(":consult ")) {
                consult(cmd.substring(":consult ".length()).trim());
            } else if (cmd.equals(":trace on")) {
                engine.setSpy(true);
                emit("trace: on");
            } else if (cmd.equals(":trace off")) {
                engine.setSpy(false);
                emit("trace: off");
            } else if (cmd.startsWith(":spy ")) {
                String pred = cmd.substring(":spy ".length()).trim();
                SolveInfo s = engine.solve("spy(" + pred + ").");
                emit(s.isSuccess() ? ("spy: " + pred) : ("failed to spy: " + pred));
                try { engine.solveEnd(); } catch (Throwable ignored) {}
            } else if (cmd.startsWith(":nospy ")) {
                String pred = cmd.substring(":nospy ".length()).trim();
                SolveInfo s = engine.solve("nospy(" + pred + ").");
                emit(s.isSuccess() ? ("nospy: " + pred) : ("failed to nospy: " + pred));
                try { engine.solveEnd(); } catch (Throwable ignored) {}
            } else if (cmd.equals(":quit")) {
                System.exit(0);
            } else if (cmd.equals(":reset")) {
                engine.clearTheory();
                emit("reset.");
            } else {
                emit("unknown meta: " + cmd);
            }
        } catch (Throwable e) {
            emit("ERROR: " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    private static void consult(String path) {
        try {
            String content = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
            Theory t = new Theory(content);
            engine.setTheory(t);
            emit("consulted: " + path);
        } catch (Throwable e) {
            emit("ERROR consulting " + path + ": " + e.getMessage());
        }
    }

    private static void runQuery(String goal) {
        try {
            String g = goal.trim();
            if (g.startsWith("?-")) g = g.substring(2).trim();
            try { engine.solveEnd(); } catch (Throwable ignored) {}
            lastSolve = engine.solve(g);
            printSolve(lastSolve);
        } catch (Throwable e) {
            emit("ERROR: " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    private static void printSolve(SolveInfo info) {
        try {
            if (info == null) { emit("no solve."); return; }
            if (!info.isSuccess()) { emit("false."); return; }

            List<Var> vars = null;
            try { vars = info.getBindingVars(); } catch (Throwable ignored) {}

            StringBuilder sb = new StringBuilder();
            boolean any = false;
            if (vars != null) {
                for (Var v : vars) {
                    if (v == null) continue;
                    String name = v.getName();
                    if (name == null || name.isEmpty() || name.startsWith("_")) continue;
                    Term val;
                    try { val = v.getTerm(); } catch (Throwable ex) { continue; }
                    if (val == null) continue;
                    if (any) sb.append(",\n");
                    sb.append(name).append(" = ").append(val.toString());
                    any = true;
                }
            }
            if (!any) sb.append("true");
            sb.append(info.hasOpenAlternatives() ? " ;" : ".");
            emit(sb.toString());
        } catch (Throwable e) {
            emit("ERROR printing solve: " + e.getMessage());
        }
    }

    private static void emit(String s) {
        synchronized (outLock) {
            System.out.println(s);
            System.out.flush();
        }
    }

    private static void endBlock() {
        synchronized (outLock) {
            System.out.println(END);
            System.out.flush();
        }
    }
}
