# Code Execution HTTP Service

## Overview
This service accepts source code and optional test/checker data over HTTP, executes the code in an isolated filesystem jail, and returns the execution result. It is designed to be fast, stateless, and container-friendly.

## HTTP API

### `POST /run`
Execute user code.

Request JSON:
- `timeout` (optional string): Execution limit, e.g. `"30s"`. Defaults to 30 seconds.
- `solution_text` (string): Source code to run.
- `lang_slug` (string): Language identifier. Supported values:
  - `clojure`, `cpp`, `csharp`, `dart`, `elixir`, `golang`, `haskell`, `java`, `js`, `kotlin`, `php`, `python`, `ruby`, `rust`, `swift`, `ts`, `zig`
- `asserts` (optional string): JSON test data, stored as `asserts.json`.
- `checker_text` (optional string): Checker code. Required for:
  - `cpp`, `csharp`, `dart`, `java`, `golang`, `haskell`, `kotlin`, `rust`, `swift`, `zig`

Response JSON:
- `exit_code` (integer or null): Process exit code, if available.
- `stdout` (string): Captured standard output.
- `stderr` (string): Captured standard error.

### `GET /health`
Returns HTTP 200 when the service is ready.

## Execution Flow
1. Validate request parameters.
2. Create a temporary filesystem jail using an overlay of the current root.
3. Write input files into a language-specific working directory:
   - `solution_text` → language-specific filename (e.g. `solution.py`, `Solution.java`).
   - `checker_text` (if provided) → language-specific checker file.
   - `asserts` (if provided) → `asserts.json`.
4. Execute `make test` inside the jail.
5. Enforce timeout; on expiration, terminate the process group.
6. Capture `stdout` and `stderr` and return them with the exit code.

## Files and Layout Expectations
The service runs `make test` in its working directory. That directory is expected to contain language-specific runner logic. The service writes files into a subdirectory:
- `check/` for most languages
- `lib/` for Dart

## Language File Rules
For each request, the service writes the solution and (if required) checker files into the language directory (`check/` or `lib/`). It then runs `make test`, which is responsible for compiling/executing the solution and checker for that language.

Filename mapping and checker requirement:
- `clojure`: `solution.clj` (no checker)
- `cpp`: `solution.cpp` + `checker.cpp` (checker required)
- `csharp`: `Solution.cs` + `Checker.cs` (checker required)
- `dart`: `solution.dart` + `checker.dart` (checker required)
- `elixir`: `solution.exs` (no checker)
- `golang`: `solution.go` + `checker.go` (checker required)
- `haskell`: `Solution.hs` + `Checker.hs` (checker required)
- `java`: `Solution.java` + `Checker.java` (checker required)
- `js`: `solution.js` (no checker)
- `kotlin`: `solution.kt` + `checker.kt` (checker required)
- `php`: `solution.php` (no checker)
- `python`: `solution.py` (no checker)
- `ruby`: `solution.rb` (no checker)
- `rust`: `solution.rs` + `checker.rs` (checker required)
- `swift`: `solution.swift` + `checker.swift` (checker required)
- `zig`: `solution.zig` + `checker.zig` (checker required)
- `ts`: `solution.js` (no checker)

## Isolation and Safety
- The execution occurs in a chrooted directory backed by an overlay filesystem.
- On Linux, it creates new namespaces (filesystem, file descriptors, mount, network) before chrooting.
- The service runs commands in a separate process group for reliable termination.

## Runtime Notes
- If the process is PID 1 (container init), it spawns a child and acts as a signal reaper to avoid zombie processes.
- The service is stateless; each request creates a fresh jail and cleans it up after execution.
