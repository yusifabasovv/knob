import os

/// Diagnostics: `log show --last 5m --predicate 'subsystem == "dev.yusifabasov.knob"' --info`
let log = Logger(subsystem: "dev.yusifabasov.knob", category: "app")
