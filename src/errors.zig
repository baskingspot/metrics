//! The one error set every writer in this module returns.
//!
//! The sink's own failure, plus the six input checks. A wrong name, a bad label
//! value, or a bucket count that disagrees with its total costs the whole
//! scrape at the parser, so each is an error rather than bytes.
//!
//! The comptime door never returns the first four: it turns them into compile
//! errors instead. One set for both doors means a caller writes one `catch`.

const std = @import("std");
const Io = std.Io;

pub const Error = Io.Writer.Error || error{
    /// A metric name outside `[a-zA-Z_:][a-zA-Z0-9_:]*`.
    InvalidMetricName,
    /// A label name outside `[a-zA-Z_][a-zA-Z0-9_]*`.
    InvalidLabelName,
    /// A label value or help text that is not valid UTF-8.
    InvalidLabelValue,
    /// A histogram descriptor through `family`, or the reverse.
    MismatchedKind,
    /// A labels struct that carries `le` on a histogram family.
    DuplicateLabel,
    /// Histogram limits that are not ascending, or counts that are not
    /// cumulative or disagree with the total.
    InvalidHistogram,
};
