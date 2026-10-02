#!/usr/bin/env python3
"""Summarise a vsync-probe dump of `:MdPreview bench` (see probe.m).

Looks at the full-speed part of the held-key scroll (0.45-1.0 s after motion starts)
and counts vsyncs whose step differs from the median: stalls (no new commit by that
vsync) and doubles (two commits shown at once) read as judder on screen.
"""
import statistics
import sys

rows = [line.split('\t') for line in open(sys.argv[1]).read().split('\n') if line]
samples = [(float(t), float(y)) for t, y in rows]
steps = [samples[i - 1][1] - samples[i][1] for i in range(1, len(samples))]
moving = [i for i, dy in enumerate(steps) if dy > 3]
if not moving:
    sys.exit('no motion recorded')
steady = steps[moving[0]:moving[-1] + 1][54:118]
median = statistics.median(steady)
print('vsyncs %d  step %.0f px  stalls %d  doubles %d  uneven %d' % (
    len(steady), median,
    sum(1 for d in steady if d < 1),
    sum(1 for d in steady if d > 1.6 * median),
    sum(1 for d in steady if abs(d - median) > 1)))
