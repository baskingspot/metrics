# Changelog

All notable changes to metrics are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.0] - 2026-11-08

### Added

- `histogram.Fixed(S, bounds)`: a bucket array, a count, and a sum over the caller's recording counter type, with `observe`, `count`, `sumValue`, and `counts`. Buckets are cumulative at observe, the sum is exact because the slot is an integer counter, and the bounds are comptime.
- `gauge.Local(T)` and `gauge.Atomic(T)`: a number that moves both ways, with `set`, `add`, `sub`, `inc`, `dec`, `get`, and `zero` to make one. The integer may be signed, and the float is `f32` or `f64`. An atomic float is an integer atomic holding the bit pattern, added through a compare-exchange loop.
- `counter.Local(T)` and `counter.Atomic(T)`: an unsigned integer and an add, with `inc`, `add`, and `get`. Both wrap at `maxInt(T)`. There is no `set` and no write method.
- The recording types and the answer they write through are separate: `metrics.prometheus.Writer` is one exposition format, and `counter`, `gauge`, and `histogram` sit beside it rather than inside it.

### Changed

- The writer moved from `metrics.Writer` to `metrics.prometheus.Writer`, so a second exposition format can sit beside it. This breaks every call site on 0.1.0; see the guide's install section for the import.

## [0.1.0] - 2026-11-06

### Added

- `Writer` is the expfmt cursor: `help`, `kind`, `name`, `value`, and `line` write one record each, and `writeMetric`, `writeFamily`, `writeHistogram`, and the series form are methods on it built only out of those five.
- `Writer.writeMetric` writes one sample line, `Writer.writeFamily` writes `# HELP` and `# TYPE` and returns the handle for its samples, and `Writer.writeHistogram` writes a classic histogram. Each is built only from `Writer` methods.
- `FamilyWriter.writeHistogramSeries` writes one series with no header, so a multi-series histogram family writes the header once and loops. `sum` is `anytype` in both histogram writers, so a `u64` above 2^53 keeps every digit.
- Values follow `metrics/common`'s rule: a float that reads back as an integer is written as one, so `1e6` is `1000000` and `-0` is `0`; `NaN` and the infinities are canonical; everything else is Go's `'g'` with the shortest digits. A value outside the `i64` range falls through instead of trapping.
- Label values and help text are escaped. A metric name or label name a parser would reject does not compile, and a label in the reserved `__` namespace does not either.
