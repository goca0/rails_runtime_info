# Validation record

## Version 0.4.0 - executed on 2026-11-16

Environment: Linux x86_64, kernel 6.18.57, MRI Ruby 3.3.8, Minitest 5.20.0,
JSON 2.7.2, RubyGems 3.6.7 and Bundler 2.5.22. No Rails application was booted.
Rails, Rack, Passenger and Puma are not installed in this environment.

Development started from the supplied v0.3.0 full bundle at
`4a362960a00c87cfe8dd4d7386e4bc2c501e4d80`. Its unchanged baseline passed with
147 tests and 736 assertions. Previous commits and annotated tags are retained.

The 0.4.0 standalone suite passed with **178 tests, 891 assertions, zero
failures, zero errors and zero skips**, with seeds 24680 and 43210:

```sh
ruby script/test --seed 24680
```

```sh
ruby script/test --seed 43210
```

These tests require neither Rails nor Rack nor Bundler. There are 31 new tests.
The new suite combines synthetic old-kernel/API scenarios with actual local
Linux native-thread reads; neither is a substitute for a CentOS 6 deployment
check. Existing Passenger/Puma tests still use synthetic server objects.

## New regression coverage

- A positive native TID selects /proc/self/task/<TID>/stat without needing or
  touching /proc/thread-self. The parsed TID must agree with the requested ID.
- An absent native-ID method, nil, negative/zero values, non-Integers and opaque
  unexpected objects use the thread-self fallback without coercion. Reader
  exceptions, including LoadError and NotImplementedError, do not prevent a
  usable fallback.
- Missing, denied, oversized, malformed and mismatched task-stat data are
  exercised. Each path is attempted at most once. Missing facilities omit the
  field; unexpected unrecovered errors remain diagnosable rather than silently
  producing an invented age. No fallback to the process PID is made.
- Stat parsing handles spaces, newlines and parentheses in comm. Positive task
  IDs and nonnegative ticks are checked. Clock rates, uptime and resulting ages
  are validated before use. Deterministic fixtures check the lifetime formula
  and the unchanged process-lifetime output shape for valid input.
- Default selection includes current-thread data. Whole-section and nested
  exclusions skip discovery or age calculation as appropriate. TID-only output
  does not obtain clock ticks or read uptime. Age-only projection and parent
  reset semantics work without changing existing output ordering/body defaults.
- Discovery failures are isolated to process.linux.current_thread. Lifetime
  failures keep the TID and use the nested lifetime error path. Ordinary errors
  are isolated; SystemExit and NoMemoryError propagate. Non-Linux selection
  skips discovery entirely.
- No new thread enumeration or thread-local mutations occur in the collector.
  Repeated reads are fresh, not cached. Weak-reference testing confirms the
  response does not retain the intermediate stat hash. Forced GC is used only
  in tests, never in library code.
- Actual local /proc/self/task/<TID>/stat and /proc/thread-self/stat reads agree
  on the sampled native task/start ticks. Three concurrent live Ruby request
  threads produce distinct native TIDs, each matching its own native_thread_id,
  and nonnegative ages. Workers remain alive until all samples are taken to
  avoid TID reuse affecting the distinctness check.
- The implementation and gemspec both report version 0.4.0.

Existing tests continue to cover server counters, require-time isolation,
request/environment lifetime, activated gems only, default unread bodies,
bounded opt-in bodies, permanent server-secret omissions, complete available
GC/YJIT hashes, optional APIs, serialization and selection/error handling.
All credential fixtures are synthetic; no live request/ENV dumps are committed.

## Other executed checks

- All 27 Ruby library/test/gemspec/build/script files passed `ruby -c` under
  Ruby 3.3.8. This is not a Ruby 2.4 or Ruby 3.4 parser/execution check.
- `gem build rails_runtime_info.gemspec` succeeds with no runtime dependencies.
  The deliberately unspecified homepage still produces its expected warning.
- The built gem was extracted into a temporary directory and loaded from its
  packaged library in a fresh Ruby process. Live native task discovery, a
  forced thread-self fallback, process lifetime, version, selective collection,
  response length/status and body release passed without gem installation.
- `ruby script/bundler_smoke` passes with Bundler 2.5.22 in both automatic and
  explicit loading modes. Temporary Gemfiles point only at the local gem;
  no remote dependency source, package installation or Rails boot was used.
  The expected no-global-source warning remains. Bundler may create its own
  temporary lockfile; the diagnostic endpoint does not read lockfiles.
- `git diff --check` passes. Ruby and Linux documentation were reviewed; source
  references are in docs/DESIGN.md, not claims of additional tested platforms.

## Explicitly not executed

**CentOS 6 / Red Hat Linux 2.6.32, Ruby 3.4.x, Ruby 2.4/2.5, and actual Rails,
Passenger or Puma integration have not been run.** Old-kernel absence and
optional API behavior are simulated, while real procfs testing uses the Linux
and Ruby versions listed above. The feature is intended to support those older
kernels via the task-directory interface; this is not certified runtime coverage.
Ruby 2.4+ and Rails 5.1+ remain implementation targets.

M:N scheduling/migration, a non-Linux host, actual enabled YJIT, restricted
production procfs mounts, ingress authentication and deployed middleware chains
were not exercised. Passenger Enterprise's private internals were not inspected
or run. The reported lifetime is that of a sampled native task, not a guaranteed
Ruby Thread-object birth time or request duration.

`script/rack_lint` reports Rack unavailable and exits 2. No Rack::Lint result is
claimed and no dependencies were installed to obtain one. No database, network
service, Passenger control socket or server-management command was used.

## Deployment acceptance checks still needed

Through the existing protected route, request:

```text
?what=-all,process.linux.lifetime,process.linux.current_thread,errors
```

Confirm the serving worker returns a plausible process lifetime and a native
thread TID/lifetime on its actual Ruby/kernel pair, especially a CentOS 6 worker
running Ruby 3.4.x. Missing facilities should omit the thread section; unexpected
failures should leave other information available. Check TID-only selection and
whole-section exclusion. Do not assume process-wide uniqueness of a thread TID
across worker restarts or equivalence to a Ruby Thread object's lifetime.

Retain prior acceptance checks for Passenger/Puma counters, ordinary application
requests, default unread bodies, bounded opt-in body capture, request IDs,
forbidden framework-key omissions and ingress protection on alternate paths.
Do not commit live diagnostic output. This record is bounded evidence, not a
promise against arbitrary monkey patches, blocking readers, fatal VM failures
or resource exhaustion. Earlier validation reports remain in Git history and
all previous release tags.
