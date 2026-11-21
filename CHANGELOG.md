# Changelog

## Unreleased

- Use stdlib 0.4.1 output functions and preserve write errors in snapshot review.

## 1.0.0

- Initial release of `poke`.
- Assertions, structured failures, regression cases and deterministic properties.
- Persisted typed counterexamples and state-aware command generation/shrinking.
- Reject blocked corpus directories consistently on Windows, Linux and macOS.
- Plain value snapshots in `test/snapshots`, with interactive review.
- Compact diff gutters, grapheme-aware wrapping, width refresh and precise newline changes.
- Scoped fixtures, process helpers and nested standard-output capture.
- Licensed under the Apache License, Version 2.0.
