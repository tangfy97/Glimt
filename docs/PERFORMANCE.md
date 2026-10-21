# Performance

## Budgets

| Measure | Budget | Measured |
|---|---|---|
| Key press to new picture committed to Core Animation | < 16 ms | p50 ~3 ms, p95 < 5 ms, max < 10 ms |
| Holding an arrow key (30 ms repeat) | a picture on every turn | 200 of 200 |
| Pinch zoom and pan | display refresh rate, no hitches | system-composited; verify with Instruments |
| Launch to window | < 300 ms | 270–295 ms on an idle machine |
| List a 10,000-item folder | < 1 s | ~0.2 s (tags follow in the background) |
| Fill the grid, thumbnails cached on disk | | ~3 ms |
| Fill the grid, thumbnails not cached (24 MP originals) | | ~275 ms |
| Actual size to full-resolution swap (24 MP) | | ~180 ms |
| Memory when idle | < 80 MB | ~19 MB |
| Memory while viewing | bounded | decode cache ≤ 512 MB, thumbnails ≤ 160 MB |
| App size | < 5 MB | 1.6 MB (1.4 MB zipped, 1.9 MB DMG) |

Measured on a MacBook Pro with M1 Pro and 32 GB, 3024 × 1964 display, macOS 27, with the fixtures below. Page turns are measured from the key event to the end of the Core Animation commit, the moment the frame is handed to the render server.

## Measuring

Generate test images first. This writes 46 photos (24 and 50 MP JPEGs, a rotated one, a 16-bit PNG, a tiny PNG and a corrupt file) and a folder of 10,000 clones (APFS clones, so they take no extra space) into `.fixtures/`, which is ignored by git:

```bash
scripts/make-fixtures.sh
```

Then build Release and run the benchmark: folder, number of page turns, milliseconds between turns.

```bash
scripts/bench.sh .fixtures/10k 150 120
```

Add `GLIMT_BENCH_VERBOSE=1` to print every page turn slower than 8 ms. Use 30 ms between turns to simulate key repeat.

For pinch zooming and scrolling, record with Instruments' Animation Hitches template; the `Decode` and `Page Turn` intervals appear under Points of Interest.

## Pitfalls

- **App Nap.** A window launched from a shell that sits behind other windows is throttled after about 30 seconds, which inflates timings. The benchmark opts out of App Nap; do the same in any new measurement.
- **The first run after a build** includes code-signature checks and cold caches. Run twice and use the second.
- **Machine load.** Compare builds by interleaving runs on the same machine at the same time, not against numbers from another session.
