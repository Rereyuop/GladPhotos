#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/GladPhotosExternalMediaBenchmark"
MODULE_CACHE="${TMPDIR:-/tmp}/GladPhotosExternalMediaBenchmarkModuleCache"
mkdir -p "$MODULE_CACHE"

swiftc -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/Scripts/benchmark_external_media.swift" \
  "$ROOT_DIR/GladPhotos/Models/ExternalMediaItem.swift" \
  "$ROOT_DIR/GladPhotos/Services/ExternalMediaIndexStore.swift" \
  "$ROOT_DIR/GladPhotos/Services/ExternalMediaScanner.swift" \
  "$ROOT_DIR/GladPhotos/Services/ExternalDiskThumbnailCache.swift" \
  "$ROOT_DIR/GladPhotos/Services/ExternalThumbnailService.swift" \
  "$ROOT_DIR/GladPhotos/Services/PerformanceLogger.swift" \
  -lsqlite3 \
  -o "$OUTPUT"

"$OUTPUT" "$@"
