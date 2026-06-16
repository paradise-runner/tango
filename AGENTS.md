# Repository Guidelines

## Project Structure & Module Organization

Tango is a Gleam application targeting Erlang. Production code lives in
`src/`; `src/tango.gleam` is the executable entry point and `src/tango/cli.gleam`
defines the operator-facing command surface. Keep domain types and validation in
`src/tango/domain/`, persistence behind `src/tango/store/`, external integrations
under `src/tango/agent/`, `registry/`, and `workspace/`, and OTP/runtime behavior
in the runtime, orchestrator, worker, and supervisor modules.

Tests live in `test/` and generally mirror the module or feature they exercise,
for example `src/tango/scheduler.gleam` and `test/scheduler_test.gleam`.
`SPEC.md` is the behavioral contract, `docs/architecture.md` is the implementation
blueprint, and `TODO.md` tracks remaining work. Do not edit generated `build/`
contents.

## Build, Test, and Development Commands

- `mise exec gleam@latest -- gleam check`: compile and type-check the project.
- `mise exec gleam@latest -- gleam test`: run the full Gleeunit suite.
- `mise exec gleam@latest -- gleam format --check src test`: verify formatting.
- `mise exec gleam@latest -- gleam format src test`: format source and tests.
- `mise exec gleam@latest -- gleam run -- help`: run the CLI locally.

Run all three validation checks before submitting changes.

## Coding Style & Naming Conventions

Use standard `gleam format` output: two-space indentation, trailing commas in
multiline values, and one module per file. Name modules and functions with
`snake_case`, public types and constructors with `PascalCase`, and tests with a
descriptive `_test` suffix. Prefer explicit domain types and `Result` errors over
stringly typed control flow. Keep adapters thin and place durable behavior in
domain, application, or store modules.

## Testing Guidelines

Tests use Gleeunit and `gleeunit/should`. Add focused unit tests beside the
closest existing feature test, and include regression coverage for bug fixes.
Store changes must cover both memory and JSON-backed behavior; codec changes
must test round trips and malformed input. Runtime changes should cover recovery,
retry, and lifecycle transitions where applicable.

## Commit & Pull Request Guidelines

Git history is not present in this checkout, so no repository-specific commit
format can be inferred. Use short, imperative, scoped subjects such as
`Add merge retry recovery`. Keep commits coherent and include relevant tests.

Pull requests should explain behavior changes, reference the affected
`SPEC.md` or architecture clauses, list validation commands run, and update
`TODO.md` after verified milestones. Call out contract or persistence changes
explicitly; include terminal output or screenshots only when operator-facing
presentation changes.
