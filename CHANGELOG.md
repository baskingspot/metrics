# Changelog

All notable changes to prometheus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `sample` writes one sample line, with labels taken from a struct's field names.
- `family` writes `# HELP` and `# TYPE` once and returns the handle its samples go through.
- `histogramFamily` writes `_bucket`, `_sum`, and `_count` from the caller's limits and cumulative counts.
- Values are written the way `prometheus/common` writes them, so a `u64` above 2^53 keeps every digit and `1e300` takes five bytes instead of 301.
- Label values and help text are escaped, and invalid UTF-8 returns `error.InvalidUtf8`.
