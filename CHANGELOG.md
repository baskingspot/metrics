# Changelog

All notable changes to prometheus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `writeMetric` writes one sample line: the name, the labels from a struct's field names, the value, and a newline.
- `writeFamily` writes `# HELP` and `# TYPE` and returns a `FamilyWriter` whose `write` writes that family's samples.
- `writeHistogram` writes a whole classic histogram: one `_bucket` line per limit, the implicit `+Inf` bucket from the count, `_sum`, and `_count`.
- Values follow `prometheus/common`'s rule: a float that reads back as an integer is written as one, `1e6` is `1000000`, `-0` is `0`, `NaN` and the infinities are canonical, and everything else is Go's `'g'` with the shortest digits.
- Label values and help text are escaped. A metric name or label name a parser would reject does not compile, and a label in the reserved `__` namespace does not either.
