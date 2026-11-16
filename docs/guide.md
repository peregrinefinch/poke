# Testing with Poke

Poke is an ordinary Pooka package. Keep using `test "name" { ... }`,
`test skip "name" { ... }` and `pooka test`. The compiler still discovers tests,
isolates their output, reports failures and chooses the exit status.

Add Poke as a development dependency:

```sh
pooka add poke --dev
```

## Unit tests

```pooka
import poke/should

test "a pair of pairs" {
  should.equal(2 + 2, 4)
  should.equal(should.be_ok(Ok("owl")), "owl")
  should.be_none(None)
}
```

Comparison arguments are actual first, expected second. `equal_named` adds a
label, preserving the native runner's expected/got details. `be_ok`, `be_error` and
`be_some` return the carried value and fail if its wrapper is wrong. `attempt`
turns an exception into `Error(String)` when testing failure behaviour itself.

## Properties

```pooka
import poke/should
import poke/generator
import poke/property
import pooka/list

test "reverse is its own undo" {
  property.for_all(
    generator.list_of(generator.integers(-100, 100), 30),
    fn(values: List(Int)) {
      should.equal(list.reverse(list.reverse(values)), values)
    }
  )
}
```

The default is 100 cases, seed 2026, maximum size 50 and 100 shrink attempts.
Use `for_all_with(source, assertion, property.Config(seed, cases, size, shrinks))`
to choose them explicitly. Cases must be positive; size and shrink budgets may
be zero but cannot be negative.

A failure prints the original value, a smaller failing value, the initial seed,
the failing trial, its sampling seed and its size. To inspect failures as data,
use `property.check(source, fn(value) { ...Bool... }, config)`, which returns a
`Result(Report, Failure(a))`. Replay its original sample with:

```pooka
property.replay(source, failure.case_seed, failure.size)
```

Generators include bounded integers, booleans, choices, constants, lists,
strings, pairs and mapping. Integer generation deliberately favours zero and
endpoints; it is neither uniform nor suitable for cryptography. Size bounds list
lengths and decreases for nested draws. A custom class may implement the open
`generator.Generator(a)` interface with `sample` and `shrink` methods.

Shrinking tries domain-preserving candidates, remembers visited values and
spends a bounded budget. It finds a smaller failure, not a proof of the globally
smallest one. Arbitrary mapped generators do not shrink because their mapping
has no inverse. Strings made of arbitrary fragments shrink to empty; supply a
custom generator for richer text shrinking.

Properties should be pure: shrinking invokes them again. Assertions and other
exceptions count as failures. Callbacks and custom generators have no automatic
timeout; a callback that never returns still needs the outer test job's timeout.

## Regressions

```pooka
import poke/regression
import pooka/string

test "names we once mishandled" {
  regression.check([
    regression.Case("padded-name", " owl ", "owl"),
    regression.Case("empty-name", "", "")
  ], string.trim)
}
```

Give cases the issue or behaviour they protect. Each input is evaluated once;
the first failed comparison reports that label and its expected/got values.
An exception from the function remains an ordinary test failure.

## Snapshots

```pooka
import poke/snapshot

test "welcome message" {
  snapshot.snap("Welcome, owl!\n", "welcome")
}
```

The first run fails and writes `test/snapshots/welcome.new`. It does not
create an accepted result. Review the candidate, then accept it as
`welcome.accepted`. Later tests pass only while the text matches exactly.
Changed text stages another `.new` file and leaves the accepted file untouched.
Matching the old accepted text again removes a stale candidate.

Snapshot names need 1–120 ASCII letters, digits, hyphens or underscores. Names
are not silently slugged, so different titles cannot collapse onto the same
file. Give parallel tests distinct names. `snapshot.Store("other/directory")`
provides `check`, `pending`, `preview`, `accept` and `reject` for custom stores.
`check` returns a `Result` instead of failing the test itself.

Files contain exact UTF-8 text: no terminal colours or metadata are added.
Newlines, empty text and Unicode remain significant. For a value snapshot,
choose a stable textual representation explicitly, for example
`snapshot.snap(should.inspect(value), "parsed-value")`.

## Reviewing

Keep Poke in `[dev-dependencies]` and run the reviewer from your project:

```sh
pooka run -m poke review
pooka run -m poke review --name welcome
pooka run -m poke list
```

The selected tool receives all arguments after `poke`. A separator still works
for existing scripts. The reviewer uses the current project's `test/snapshots`.
To use another store, supply `--directory /path/to/test/snapshots`.

You can also export the standalone command from the Poke package:

```sh
pooka export escript
./build/poke --help
```

Run that executable from the project whose snapshots you want to review, or
pass `--directory`. Erlang must be installed. Review choices are:

| Key | Action |
| --- | --- |
| `a` | Accept the current candidate |
| `r` | Reject the candidate, retaining accepted text |
| `s` | Skip it |
| `d` | Toggle the diff and the plain candidate |
| Enter on its own | Redraw using the current terminal width |
| `q` or EOF | Stop and leave remaining candidates alone |

`list` lists candidates. `accept` and `reject` apply to all pending candidates;
add `--name welcome` to select one. Those bulk commands are explicit review
actions, never test-runner behaviour. Acceptance writes the complete new file
before renaming it into place. Failed writes retain the pending candidate.

The reviewer follows Birdie's single-column layout: progress, a title/file
header, an old/new legend, numbered diff gutters and a vertical action menu.
Removals are red and additions green. Pooka's orange/amber controls and violet
headings and separators frame the diff; ordinary context stays muted.

Shared lines between separate edits are retained, and long unchanged runs are
folded. Final-newline differences are shown explicitly. Alignment uses a bounded
LCS table; above 40,000 cells it falls back to prefix/suffix matching to bound
memory. Long lines wrap at grapheme boundaries without dropping text. Wider terminals
show more on each row; after resizing, press Enter to redraw at the new width. Terminal controls are shown visibly rather than executed.

Type an action key and press Enter. `d` hides the changes and shows the complete
candidate as plain numbered text; pressing it again restores the diff. The
interactive reviewer stays single-column at every width. A final summary counts
accepted, rejected and skipped candidates. If another test run changes a
candidate while the prompt is open, acceptance stops for another review.

`NO_COLOR` overrides `FORCE_COLOR`; redirected and dumb terminals stay plain
unless forced. `--no-color` always selects plain text.

Commit `.accepted` files with their tests. Review `.new` files rather than
accepting them automatically in CI.

## Formatting richer values

`poke/pretty` is bundled with Poke. It formats nested classes, Unicode text,
sets, dictionaries, optional values and errors as plain text. Choose a fixed
width for value snapshots; `snapshot.value_with` preserves all values even when
display limits are supplied. Diff colours belong to the reviewer, not the value
formatter.

## Fixtures

`fixture.with_directory(fn(path) { ... })` creates a unique directory beneath
`build/poke-fixtures` and removes its contents after success or failure.
`fixture.with_resource(setup, cleanup, run)` runs cleanup once if setup succeeds.
Keep allocation outside workers that may be killed: process death cannot execute
an Erlang `after` block.

## Processes and actors

```pooka
import poke/process
import poke/should

test "a worker answers" {
  let replies = process.channel()
  should.be_ok(process.within(1000, fn() { replies.send(42) }))
  should.equal(replies.expect(1000), 42)
}
```

A channel receives only in its owner process. Its unique tag keeps other
channels' messages untouched. `receive` returns `Result`; `expect` asserts a
successful receive. All deadlines are explicit milliseconds.

`within(milliseconds, callback)` returns the result or a crash/timeout error.
It kills and joins its worker on timeout. `crashes` requires a real crash and
rejects normal returns and timeouts. `with_task` owns a worker for one callback;
`with_process` adopts an existing test-owned process or actor and joins it during
cleanup. Neither helper owns that process's descendants.

## State models

`model.check(commands, initial, predict, perform)` compares each real operation
with a pure prediction. `predict` returns `#(next_state, expected_reply)` and
`perform` returns the real reply. Mismatches name the command and step.

For state-dependent commands, implement `model.Commands(state, command, reply)`:

- `initial()` supplies the initial model state.
- `generate(state, seed, size)` returns a `Sample(Option(command))`; `None` ends a sequence.
- `valid(state, command)` declares a precondition.
- `predict(state, command)` returns the next model and expected reply.
- `shrink(command)` supplies smaller commands.

Use `model.commands(machine, maximum)` as a property generator. It advances the
model while sampling. Shrinking removes commands and shrinks individual values,
then checks the *whole* candidate: removing a push must not leave a later pop
on an empty stack. An invalid generated command fails immediately.

```pooka
property.for_all(model.commands(machine, 30), fn(commands) {
  let service = Counter()
  let _ = process.with_process(service.pid(), fn(_) {
    model.check_commands(commands, machine, fn(command) { service.perform(command) })
  })
  Nil
})
```

The application supplies `machine` and `Counter`. Create fresh real state for
every trial and shrink attempt. `check_commands` validates the complete sequence
before the first real effect. Generation and prediction must be pure.

## A counterexample corpus

`corpus.Store(directory)` persists minimized values. `corpus.defaults()` uses
`test/counterexamples`; commit these small regression inputs with your tests.
Each property owns a safely named subdirectory, containing hashed `.case` files.
Identical values deduplicate, including concurrent discoveries.

The application implements `corpus.Codec(value)`, with `encode(value) -> String`
and `decode(text) -> Result(value, String)`. The decoder validates stored values;
Poke never evaluates text as code or deserializes an unchecked runtime term.

```pooka
class IntegerText with corpus.Codec(Int) {
  encode(value: Int) -> String { int.to_string(value) }

  decode(text: String) -> Result(Int, String) {
    match int.parse(text) {
      Ok(value) -> Ok(value)
      Error(_) -> Error("expected an integer")
    }
  }
}

test "adding zero preserves an integer" {
  corpus.defaults().for_all("adding-zero-v1", generator.integers(-100, 100),
    IntegerText(), fn(n) { should.equal(n + 0, n) }, property.defaults())
}
```

Saved values run first. A failing saved example prevents fresh generation;
a passing corpus is followed by the configured random trials. A newly minimized
failure is saved before reporting it. `Store.check` returns structured data
instead of raising; `Store.examples` reads and validates values independently.
Malformed files, invalid names and storage errors stay visible. A failure that
could not be saved is still reported with its value and storage error.

Change the property name when its encoding or valid domain changes. A codec is
also responsible for domain checks: a decoded command must still make sense to
the current test. The random report's case count excludes corpus replay.

## Structured failures

`failure.capture(callback)` returns `Result(value, failure.Failure)` for all
assertion families, Pooka panic and foreign exceptions. A failure contains a
`kind`, `message`, and optional `expected`/`actual` text. Comparisons use the plain
snapshot formatter with no depth or item truncation.

```pooka
let problem = failure.capture(fn() { should.equal([1], [2]) }) |> should.be_error()
should.equal(problem.kind, failure.Kind.Comparison)
should.equal(problem.expected, Some("[2]"))
```

`failure.compare(actual, expected, label)` builds a comparison result without
raising. `failure.describe(problem)` renders a complete plain report.
`should.attempt` remains a convenience that returns `Error(String)`. No runner
extensions are involved: assertions raise the native comparison/failure terms.

## Capturing output

```pooka
let found = capture.output(fn() {
  should.be_ok(io.println("hello"))
  42
})
should.equal(found.value, 42)
should.equal(found.text, "hello\n")
```

`capture.attempt` returns the text alongside a `Result` carrying a structured
failure. `capture.output` re-raises exceptions after restoring the original
group leader. Captures nest and are isolated between concurrently running tests.
A monitored collector exits when its owner dies; successful captures join the
collector before returning.

Only standard IO routed through the group leader is captured. The library does
not replace global `standard_error`, logger handlers or registered IO devices.
Input requests are unsupported and return an IO error. Join children inside the
scope if their output matters. Capture buffers text in memory and has no
implicit deadline; use scoped fixtures and `process.within` for bounded work.

## Runtime and platform checks

Poke targets Pooka 0.3.2 or later and Erlang/OTP 29. Its CI matrix runs
unit, property, regression and snapshot checks on Linux, macOS and Windows, then
checks formatting, documentation and publication archives.

Line endings are significant in text snapshots. File APIs and IO requests use
UTF-8; corpus loading accepts the native filename representations returned by
Erlang. Process waits use explicit millisecond deadlines. Terminal display-cell
widths are estimates and may differ for ambiguous-width glyphs across fonts.


The unified diff has one aligned line-number gutter. A removed row names its
old line, and an added row names its new line. Continuations use `↪` rather than
a second line number. The preview does not clip snapshot content or impose a
maximum display width.

A first snapshot does not need a final newline. When an accepted file and its
candidate differ *only* in a trailing newline, the diff still reports that byte
change explicitly. Review never adds or removes a newline from stored content.
