# Changelog

All notable changes to prometheus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Writer` is the expfmt cursor: `help`, `kind`, `name`, `value`, and `line` write one record each and hold only the sink.
- `writeMetric` writes one sample line, `writeFamily` writes `# HELP` and `# TYPE` and returns the handle for its samples, and `writeHistogram` writes a classic histogram. Each is built only from `Writer` methods.
- Values follow `prometheus/common`'s rule: a float that reads back as an integer is written as one, so `1e6` is `1000000` and `-0` is `0`; `NaN` and the infinities are canonical; everything else is Go's `'g'` with the shortest digits. A value outside the `i64` range falls through instead of trapping.
- Label values and help text are escaped. A metric name or label name a parser would reject does not compile, and a label in the reserved `__` namespace does not either.
