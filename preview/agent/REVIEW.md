# Gate review: fresh, read-only

You are started by `preview/agent/run.py` to review one phase before its gate. Don't edit
anything: you have read-only tools, and a hook refuses writes. The SPEC is below this file. The
message gives the ranges to review in this worktree and in `~/src/neovide-agent`; a follow-up
round also lists the findings whose fixes it covers.

1. Overview: `git diff -M --stat <range>`. Then read the diff area by area
   (`git diff -M <range> -- <dir>`). Pure renames show as renames: don't read moved files in full.
   Never dump the whole diff at once; skip lockfiles. Same for the Neovide range
   (`git -C ~/src/neovide-agent diff ...`).
2. Check against SPEC:
   - no hacks or symptom fixes; root causes fixed;
   - no duplicated logic between providers/renderers; the core has no provider knowledge
     (grep the core files for `markdown`, `pdf` and provider names);
   - nothing reimplemented that a chosen library provides (pdf.js `PDFViewer`, `EventBus`,
     `PDFLinkService`, `PDFFindController`);
   - Neovide changes are generic (nothing file-type-specific) and needed;
   - tests not weakened: every change to `preview/test/adapter.lua`, unit tests, and (P3b) PDF
     scenarios has a `TEST CHANGE:` line in `preview/work/DECISIONS.md` that holds up; the adapter
     only maps the test API onto the plugin and has no logic of its own; PDF scenarios use only user
     keys/commands and adapter functions;
   - `preview/work/CONTEXT.md` is current; docs updated (after P2: `preview/CLAUDE.md`,
     `preview/docs/`, nothing from `mdpreview/CLAUDE.md` lost);
   - DECISIONS.md entries are plausible and revertible.
3. Severity:
   - BLOCKING: breaks the SPEC quality bar or architecture (a hack, a symptom fix, duplicated logic,
     provider knowledge in the core, a reimplemented library part, a non-generic Neovide change),
     weakens a test, or is a likely regression. At most 6, the most important first.
   - MINOR: everything else worth noting (naming, docs, small cleanups). They go to PENDING.md for
     Egor, not into the plan.

## Answer (your last message, at most 20 lines)
One finding per line, `BLOCKING: <what>, <where> (<why>)` or `MINOR: <what>, <where>`, or exactly
`NO FINDINGS`. Nothing else.
