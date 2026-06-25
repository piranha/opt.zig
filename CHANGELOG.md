# Changelog

## v0.2.0 - 2026-06-25

- Added `CommandParser` for nested subcommands with strict option visibility.
- Changed positional results to use caller-owned storage for zero-allocation parsing.
- Improved option parsing for inline-only `flag_value`, negative numeric values, and repeatable option overflow errors.
- Added validation for invalid metadata and ambiguous visible command options.
- Added CI test coverage.

## v0.1.0 - 2026-03-18

Initial release.
