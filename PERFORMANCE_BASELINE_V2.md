# GladPhotos Performance Baseline V2

Date: 2026-06-23

## Purpose

This baseline is the required comparison point for Phase 1 and later performance PRs. Use the same generated folders, the same app build configuration, and the same Instruments templates before comparing numbers.

## Scenarios

`Scripts/benchmark_external_media.swift` defines three `PerformanceScenario` sizes:

| Scenario | Count | Dataset mix |
| --- | ---: | --- |
| `1000-mixed-media` | 1,000 | JPG baseline, every 25th large PNG, every 40th MOV, every 50th Live Photo pair, every 97th corrupt JPG |
| `10000-mixed-media` | 10,000 | Same deterministic mix |
| `50000-mixed-media` | 50,000 | Same deterministic mix |

The benchmark prints the generated folder path. Keep that folder for Instruments runs in the same comparison session.

Run:

```sh
Scripts/run_external_media_benchmark.sh
```

Optional single scenario:

```sh
Scripts/run_external_media_benchmark.sh 10000
```

## Script Metrics

Record these values for cold and warm runs:

| Scenario | Run | Scan | First Screen P50/P95 Proxy | Scroll Proxy | Cancel Recovery | Resident Memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1,000 | Cold | TBD | TBD | TBD | TBD | TBD |
| 1,000 | Warm | TBD | TBD | TBD | TBD | TBD |
| 10,000 | Cold | TBD | TBD | TBD | TBD | TBD |
| 10,000 | Warm | TBD | TBD | TBD | TBD | TBD |
| 50,000 | Cold | TBD | TBD | TBD | TBD | TBD |
| 50,000 | Warm | TBD | TBD | TBD | TBD | TBD |

## Instruments Protocol

Use a Release build with the same generated folder. Capture:

1. First interactive UI and first screen thumbnails.
2. Fast continuous vertical scroll for 20 seconds.
3. Window resize from narrow to wide and back.
4. Month switching through the sidebar calendar.
5. Toggle media info on and off.
6. Open image detail, close it, open video detail, close it.
7. Select 100 items and delete them in a disposable benchmark folder.

Templates:

| Template | Required readings |
| --- | --- |
| Time Profiler | Main-thread longest blocking sample, repeated thumbnail decode stacks |
| SwiftUI | Body/layout invalidation spikes during scroll and resize |
| Core Animation | Average FPS, longest hitch |
| Allocations | Peak memory, memory after scroll settles for 30 seconds |
| File Activity | Cold-start bytes read, repeated thumbnail reads |

## Acceptance Gate

Every optimization PR must include:

- The scenario count and generated dataset path.
- Cold and warm script output.
- Instruments screenshots or exported traces for the workflows above.
- A short before/after table for FPS, longest hitch, main-thread block peak, duplicate decodes, peak memory, settled memory, and disk reads.
