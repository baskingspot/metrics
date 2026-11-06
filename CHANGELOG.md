# Changelog

All notable changes to prometheus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `family` and `histogramFamily` write a whole family in one call: the header and every sample, so a family's samples are contiguous by construction.
- `prometheus.runtime` writes the same families from a descriptor built at run time, for a composed name or an embedder's prefix.
- `family` and `histogramFamily` take an iterator as well as a slice, an array, or a tuple: any struct with a `next() ?Sample` method, by value or behind a pointer, so a consumer that cannot allocate streams a family instead of gathering it.
- `Family.limits` carries the histogram bucket bounds, and an empty slice is one `+Inf` bucket. The implicit `+Inf` bucket comes from the total, so a sample's last finite count may be lower.
- `error.InvalidBuckets` is returned before any byte is written, and a label name in the reserved `__` namespace no longer compiles.
- Floats are written with `prometheus/common`'s `'g'` format, so `1e300` takes five bytes instead of 301 and a scrape from this library diffs clean against a Go client's. Integers are exact decimals and never go through `f64`, so a `u64` above 2^53 keeps every digit.
- Label values and help text are escaped, and invalid UTF-8 returns `error.InvalidUtf8`. The comptime door's error sets are exact: `FamilyError` is the sink plus `InvalidUtf8`, and `HistogramError` adds `InvalidBuckets`, while `prometheus.Error` is the full set the `runtime` door returns. A bad metric name is a compile error at the comptime door and `error.InvalidName` at the runtime one; a bad label name and a `le` collision never compile, whichever door is used.
- `just bench` reports encode throughput for four cases, and `just check-corpus N SEED` gates a seeded corpus through Prometheus's own parser.
