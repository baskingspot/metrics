//! The one error set every writer in this module returns.
//!
//! The sink's own failure, plus the two input checks that keep one caller's typo
//! out of a document. A wrong name or an invalid UTF-8 label value costs the
//! whole scrape at the parser, not one series, so both are errors rather than
//! bytes.

const std = @import("std");
const Io = std.Io;

pub const Error = Io.Writer.Error || error{ InvalidName, InvalidUtf8, InvalidBuckets };
