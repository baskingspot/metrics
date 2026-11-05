//! The one error set every writer in this module returns.
//!
//! The sink's own failure, plus the input checks. A wrong name, a bad label
//! value, or a bucket count that disagrees with its total costs the whole
//! scrape at the parser, so each is an error rather than bytes.
//!
//! The comptime door turns `InvalidName` and `MismatchedKind` into compile
//! errors, and so does the runtime door for a label name or a duplicated `le`,
//! because both come from a comptime type. Every error here has a path that
//! reaches it, so a caller's `catch` arms are all real.

const std = @import("std");
const Io = std.Io;

pub const Error = Io.Writer.Error || error{
    /// A metric name outside `[a-zA-Z_:][a-zA-Z0-9_:]*`.
    InvalidName,
    /// A label value or help text that is not valid UTF-8.
    InvalidUtf8,
    /// Histogram limits that are not finite and ascending, or counts that are
    /// not cumulative or disagree with the total.
    InvalidBuckets,
    /// A histogram descriptor through `family`, or the reverse.
    MismatchedKind,
};
