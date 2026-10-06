import os

/// Diagnostics, readable with: log show --last 10m --predicate 'subsystem == "com.vinit.cadence"'
let logger = Logger(subsystem: "com.vinit.cadence", category: "dictation")
