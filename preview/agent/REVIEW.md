# Gate review: fresh, read-only

Don't edit anything. Input: a range `<base>..HEAD`. Read `preview/agent/SPEC.md` first.

1. Overview: `git diff -M --stat <range>`. Then read the diff area by area
   (`git diff -M <range> -- <dir>`). Pure renames show as renames: don't read moved files in full.
   Never dump the whole diff at once; skip lockfiles.
2. Check against SPEC:
   - no hacks or symptom fixes; root causes fixed;
   - no duplicated logic between providers/renderers; the core has no provider knowledge
     (grep the core files for `markdown`, `pdf` and provider names);
   - nothing reimplemented that a chosen library provides (pdf.js `PDFViewer`, `EventBus`,
     `PDFLinkService`, `PDFFindController`);
   - tests not weakened: list every change to `preview/test/adapter.lua`, unit tests and harness code
     with its justification; the adapter only maps the test API onto the plugin and has no logic of
     its own; PDF scenarios use only user keys/commands and adapter functions;
   - `preview/work/CONTEXT.md` is current; docs updated (after P2: `preview/CLAUDE.md`, `preview/docs/`,
     nothing from `mdpreview/CLAUDE.md` lost);
   - DECISIONS.md entries are plausible and revertible.
3. Return at most 20 lines: each finding as a task line
   `- [ ] Fix: <what>, <where> (<why>)`, or exactly `NO FINDINGS`.
