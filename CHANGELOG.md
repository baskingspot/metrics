# Changelog

All notable changes to prometheus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `family` and `histogramFamily` write a whole family in one call: the header and every sample, so a family's samples are contiguous by construction.
- `prometheus.runtime` writes the same families from a descriptor built at run time, for a composed name or an embedder's prefix.
- `Family.limits` carries the histogram bucket bounds, and an empty slice is one `+Inf` bucket.
- Values are written the way `prometheus/common` writes them, so a `u64` above 2^53 keeps every digit and `1e300` takes five bytes instead of 301.
- Label values and help text are escaped, and invalid UTF-8 returns `error.InvalidLabelValue`. A bad name is a compile error at the comptime door and `error.InvalidMetricName` at the runtime one.
- `just bench` reports encode throughput for four cases, and `just check-corpus N SEED` gates a seeded corpus through Prometheus's own parser.
