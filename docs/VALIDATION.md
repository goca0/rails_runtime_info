# Validation record

## Version 0.7.2 - review and Git validation on 2026-11-18

This is a separate commit after v0.7.1,
`7cc1ee875c2ea7c57c788beb9f93583544796123`, adding only namespace permission
fallback and related tests/documentation. It preserves all preceding history.

The same Debian 13.6 / Linux 6.18.57 x86_64 container still has **no Ruby runtime**.
No Ruby tests, Ruby syntax checks, gem build, Bundler smoke or Rack::Lint were
executed. Source and tests received independent static review; git diff --check
passed. There are 16 added namespace regression tests and one updated existing
directory-error test. The 13 limits tests added in 0.7.1 also remain unexecuted.

The new tests exercise actual Dir.foreach stubs rather than bypassing the
permission rescue. Coverage includes both EACCES/EPERM, directory-before-link
ordering, normal discovery of unknown names, incomplete enumeration, missing
directories, unrelated directory errors, mixed/all failed fallback probes,
the 4096-byte link bound, dotted/excluded/summary selectors, ordinary/fatal
exception distinctions, unchanged normal namespace and FD error entries,
readlink-only operations and immutable/request-local fallback candidates.
Existing tests retain limit-only/excluded/non-Linux no-discovery checks.

Git-only release verification restores the full bundle and applies the
incremental bundle to a separate v0.7.1 clone. It compares release commit, tree
and annotated tag, verifies clean restored working trees and runs
git fsck --full --strict. The incremental prerequisite is the v0.7.1 commit above;
users starting at v0.7.0 need the 0.7.1 incremental first. These checks establish
repository integrity, not executed Ruby behavior.

Neither PR_SET_DUMPABLE=0 nor the user's patched Ruby was exercised. Permission
failures and older missing namespace types are represented in unexecuted test
fixtures. Ruby 2.4+, Rails 5.1+, Passenger/Puma and CentOS 6 runtime compatibility
remain targets or prior documented limitations, not new validation claims.
No runtime dependencies were installed or fetched.

## Version 0.7.1 - review and Git validation on 2026-11-18

Started from the supplied v0.7.0 full bundle at
`6c327e62f3e16ebc61a5704c9e64540cc742c950`; its SHA-256 matched
`c4e85678afa43a2fdf959a087212113c821066686d0bec3bf3ba11d29cb1668f`.
Prior commits and annotated release tags are preserved. This release changes
only the process-limits representation and related tests/documentation.

The current container is Debian 13.6 on Linux 6.18.57 x86_64. **No Ruby runtime
is installed.** The standalone Minitest suite, Ruby syntax checks, gem build,
Bundler smoke test and Rack::Lint were not executed for this release. Earlier
passing results below apply to their stated releases, not to these changes.
No dependencies were installed or fetched to work around this limitation.

Static review covers Ruby 2.4-compatible syntax/APIs, one existing bounded read,
request-local data, no raw-file output, selector handling and ordinary/fatal
exception boundaries. Thirteen focused tests were added for padded/compact/tab
rows, exact 20-digit integer parsing, unlimited/absent units, CRLF, unknown
resource names, malformed rows, structured-only endpoint output, the existing
64 KiB read bound, dotted/excluded/non-Linux selectors and isolated failures.
One of those tests reads the live procfs limits when run on Linux. These tests
are present but **unexecuted** in this environment.

Release delivery verifies Git whitespace, bundle prerequisites, full restoration
and incremental application from v0.7.0, matching commit/tree/annotated-tag
objects, clean restored working trees and git fsck --full --strict. These are
repository-integrity checks, not Ruby execution. The incremental bundle requires
the v0.7.0 commit above and its history.

To execute the standalone suite in a prepared environment:

```sh
ruby script/test --seed 24680
```

Ruby 2.4+, Rails 5.1+ remain targets. This release adds no new claims of Ruby,
Rails, Passenger, Puma or CentOS 6 execution coverage.

## Version 0.7.0 - executed on 2026-11-17

Started from the supplied v0.6.0 full bundle, whose SHA-256 matched
`0890e05aa53e8ac3f6c0be91ed80a15eca12c38e9f633489c66d5d56f0677ca3`, at
`dc8576fc2757f09f4b9581415981300d298d4b85`. The unchanged baseline passed
262 tests / 1379 assertions. Prior commits and annotated release tags are
preserved. This release adds the four agreed diagnostic features; cgroup
resource reporting is deferred in TODO.md and no snapshot deltas are added.

Executed on Linux 6.18.57 x86_64, CRuby 3.3.8, Minitest 5.20.0, JSON 2.7.2,
RubyGems 3.6.7 and Bundler 2.5.22. The expanded standalone suite passed
**309 tests, 1577 assertions, zero failures, errors or skips**, with seeds
24680 and 43210. There are 47 new tests, plus updates to existing fixtures and
version/default-selection expectations. Coverage includes:

- Default core thread inventory; dead threads, nil optional IDs, missing APIs,
  singleton/subclass overrides, Ruby-defined global reader/list replacements,
  per-thread/per-field failures, unrelated diagnostics and fatal propagation.
- Inventory and backtrace thread caps, bounded backtrace arguments with exactly
  one sentinel frame, frame/text truncation, name bounds, no unbounded retry,
  no arbitrary object coercion, summary-only selection and default-off stacks.
- Thread-state preservation during concurrent diagnostic requests and natural
  thread creation/termination. The response does not retain the temporary
  enumeration array; no Thread objects are serialized. Tests use explicit GC
  only to check retention; runtime library code never forces collection.
- CPU fields 14/15 and SC_CLK_TCK conversion, invalid/overflowing data, independent
  age/CPU failures, CPU-only no-uptime behavior and TID-only no-clock behavior.
- Bounded directory enumeration with a lookahead, exact-limit semantics, readlink
  without opening targets, oversize/binary link values, vanished descriptors,
  unavailable old-kernel namespace directories, permission errors, per-link
  selection, limit-only no-discovery and non-Linux omission.
- Live local procfs CPU/namespace/FD observations and repeated directory
  enumeration without leaked directory descriptors. Transient FD ENOENT is an
  expected observation, including the enumeration directory's own descriptor.
- Default-off FD details, explicit parent inclusion, later exclusions and
  unchanged selection ordering. Failed authentication does not reach any new
  collector or body reads. Existing auth/delay/request/GC/YJIT tests still pass.

All 38 Ruby library/test/script/build/gemspec files passed ruby -c on Ruby 3.3.8.
Git diff whitespace checks passed. The gem built without runtime dependencies
(the existing missing-homepage warning remains). A separately unpacked gem,
loaded from its own lib directory in a fresh process, passed default inventory,
opt-in backtraces/FDs, CPU/namespaces, original display order, unread default body,
SSHA/PLAIN and 401/503 behavior, a real fractional sleep, HEAD and on-close JSON
release. The packaged TODO and new library file are checked by the test suite.

script/bundler_smoke passed both automatic and explicit require modes using
already-installed Bundler and temporary source-free local path Gemfiles. It
now exercises the new inventories alongside authentication and delay. The
source-free Gemfiles emit Bundler's existing deprecation warning. No dependency
was installed or fetched. script/rack_lint exited 2 because Rack is unavailable;
its new inventory cases are present but unexecuted.

Release validation also restores a fresh full-bundle clone and a separate
v0.6.0 clone fast-forwarded with the incremental bundle, runs the complete suite
in both, compares release commit/tree/annotated-tag objects, and checks bundle
prerequisites, clean working trees and git fsck --full --strict. The incremental
prerequisite is the v0.6.0 commit stated above; it is not an empty-repository
bundle. No Git identity or remote host is inferred: the owner's configured
Jan Seda identity is used, and Git bundles do not include local configuration.

Limitations: no Rails app, Passenger/Puma server, dotenv integration, Rack::Lint,
Ruby 2.4/2.5/3.4, CentOS 6, Ractor or M:N execution was tested. Source/documentation
review and synthetic old-kernel/missing-API cases are not execution coverage for
those combinations. Boundaries limit inspection/output, not every allocation or
synchronization inside the VM, Thread.list, procfs or the filesystem. Backtraces
are deliberately opt-in. No test proves immunity to VM/native-extension bugs,
strict response-time limits, atomic snapshots or all possible thread races.
These remain occasional diagnostics, not a stress profiler or health check.

## Version 0.6.0 - executed on 2026-11-17

Started from the supplied v0.5.0 full bundle at
`3495cd372514be72c161a94b947b20e635949672`. Both supplied v0.5.0 bundle
checksums matched. The unchanged baseline passed 231 tests / 1173 assertions.
All prior history and annotated release tags are preserved.

Executed on Linux 6.18.57 x86_64, MRI Ruby 3.3.8, Minitest 5.20.0, JSON 2.7.2,
RubyGems 3.6.7 and Bundler 2.5.22. The updated standalone suite passed
**262 tests, 1379 assertions, zero failures, errors or skips**, with seeds
24680 and 43210. There are 31 new tests covering:

- Missing/zero no-op; unsigned decimal integers/fractions; inclusive 30-second
  limit; exact-decimal rejection just above 30 even when Float would round it
  down; tiny positive values; invalid signs, exponent syntax and non-finite
  text; empty values; strict percent decoding and decoded/encoded size bounds.
- Repeated sleep values, including encoded key aliases, are rejected. Unrelated
  malformed values stay uninterpreted; unknown query objects are not coerced.
- Authentication-before-validation-before-sleep-before-Snapshot ordering;
  validation of both controls before waiting; reuse of the validated Selection.
  Missing/wrong/malformed credentials and unavailable auth never reach parsing,
  sleep, collectors or body input. Authenticated bad controls return 400.
- Invalid what in either query order prevents waiting and collection. Sleep is
  query-only, never sourced from headers, form caches or request body. Default
  bodies remain unread and explicitly selected bodies are collected after wait.
- Exactly one positive sleep call, never from response-body iteration/close.
  HEAD and other methods obey the delay without changing HEAD body handling.
  Original query/Authorization echo, selection defaults, display order and
  response keys remain unchanged; no dedicated sleep response field exists.
- Ordinary sleep failures use the existing static 500 fallback without
  collection. Simulated NoMemoryError, SystemExit and Interrupt propagate.
- A real 0.03-second Kernel.sleep measured with the monotonic clock, with the
  diagnostic timestamp sampled afterward. A controlled sleeping stub/barrier
  lets three authenticated requests remain pending while a fourth no-delay
  request completes through the same wrapper; request markers stay separate.
  This concurrency case is not an actual Passenger/Puma routing test.
- No retained request environment in the returned body after a delayed call;
  close releases JSON. Test-only GC and timeout/barrier machinery is not used
  in the runtime implementation. No delay-related class-instance state is kept.

All 35 Ruby library/test/script/build/gemspec files passed `ruby -c` under Ruby
3.3.8. `git diff --check` passed. `ruby script/bundler_smoke` passed automatic and
explicit loading, real bare/authenticated fractional delays, both password
formats, 401/503 and invalid query responses. Its temporary local Gemfiles have
no network source and emit the existing no-global-source warning.

`gem build rails_runtime_info.gemspec` succeeded with no runtime dependencies
and only the existing homepage warning. A separately unpacked gem, loaded in a
fresh Ruby process exclusively from its packaged lib directory, passed version,
real fractional delay, SSHA/PLAIN authentication, invalid query values/selection,
HEAD, default-unread input and response-body-release checks. No gem installation
was needed. Build artifacts are excluded from the Git repository.

No application was booted, dependency installed or network/service contacted by
the tests. Actual Rails, Passenger, Puma, dotenv-rails, ingress/client timeouts,
worker rerouting, queued requests, disconnect handling and fiber-scheduled sleep
were not tested. Ruby 2.4/2.5/3.4 and CentOS 6 execution remain untested. Ruby 2.4+
and Rails 5.1+ remain implementation targets, not newly verified combinations.
`script/rack_lint` exited 2 because Rack is not installed: its new success/400/
HEAD delay cases are present but were not executed. Ruby documentation was
reviewed separately; references are in docs/DESIGN.md.

Release distribution uses a full bundle and an incremental bundle requiring
v0.5.0's complete history through the base commit above. Bundle restoration and
repository-integrity checks are performed separately at delivery. Before using
sleep in production, confirm the real server's thread/process model and request
limits; this feature does not guarantee another PID or cancellation when a
client disconnects. A per-request delay cap does not limit concurrent occupancy.

## Version 0.5.0 - executed on 2026-11-17

Started from the supplied v0.4.1 full bundle at
`79e0e37a72d251097c1ae8ed9d1af6822d15bca6`. The unchanged baseline passed
179 tests / 894 assertions. All prior history and annotated release tags are
retained. The new feature is explicit per-route Basic authentication; existing
unauthenticated routes, diagnostics, selectors and the body-close fix remain.

Executed on Linux 6.18.57 x86_64, MRI Ruby 3.3.8, Minitest 5.20.0 and Bundler
2.5.22. The standalone suite passed **231 tests, 1173 assertions, zero failures,
errors or skips**, using seeds 24680 and 43210. There are 52 added tests covering:

- Independently generated SSHA known-answer vectors (binary salt and colon /
  non-ASCII passwords), PLAIN, multiple users, exact bytes/whitespace, comments,
  CRLF and a final unterminated line. Invalid Base64, unsalted/truncated SSHA,
  unsupported schemes, duplicate names and malformed whole files fail closed.
- Bounded Authorization and regular-file reads, including exact limits and one
  byte over; actual FIFO/directory rejection; missing/deleted/atomically replaced
  files; simulated permission errors; first-request digest-load failures.
- Basic parsing, credential rejection, case-insensitive scheme, header injection
  prevention, realm escaping, 401 challenges, 503 configuration failures and
  empty HEAD bodies. Empty credentials and control characters are rejected.
- Missing ENV path during factory invocation does not raise or read anything;
  missing files can be created later. Paths/realms are immutable snapshots and
  path changes in ENV need a new wrapper. No fallback to an open endpoint.
- Unauthenticated requests do not call Endpoint, interpret what or read input.
  Authenticated requests preserve selectors and Authorization, including its
  original Rack key. Frozen env is accepted without mutation or REMOTE_USER
  assignment. Bare endpoints stay unprotected and do not invoke authentication.
- Fresh subprocess checks confirm no boot-time I/O or external library loads,
  and no auth/diagnostic library load on a missing-credentials challenge.
  Concurrent first requests load both Digest implementations successfully;
  regular concurrent requests keep credentials/results isolated.
- Weak references confirm no retained request env or password-file string after
  checking, including failed attempts. Rejection bodies keep only static JSON
  and release it on close. Forced GC is confined to tests, not library code.
- Auth failures neither log nor expose exception messages. Ordinary exceptions,
  LoadError and NotImplementedError close access; simulated SystemExit,
  NoMemoryError and Interrupt propagate.

`ruby script/bundler_smoke` passed both automatic and explicit loading, including
SSHA/PLAIN success, wrong/missing credentials and missing configuration within
Bundler. The temporary local-path Gemfiles produce Bundler's expected warning
about an omitted global source; they intentionally have no network source.
`gem build rails_runtime_info.gemspec` succeeded, with only the existing missing
homepage warning. A separately unpacked gem passed isolated library checks for
SSHA/PLAIN, 401/503, missing file/configuration, HEAD and body cleanup; its loaded
paths were checked to exclude the working-tree library. All 32 Ruby source/test/
script/build files passed `ruby -c`, and `git diff --check` passed.

No application was booted or dependency installed. Tests made no network/service
calls. Rack remains unavailable, so the extended `script/rack_lint` exited 2;
its authentication cases were added but **not executed**. Actual Rails, Puma,
Passenger, dotenv-rails, nginx and browser integration were not tested. Ruby
2.4/2.5/3.4 execution and CentOS 6 remain untested. Source review establishes
expected formats and loading conventions, not live compatibility certification.
There was no independent security audit; fixed-size comparisons are not a claim
of whole-request constant timing or hardened public-Internet authentication.

Full/incremental artifact restoration is a separate release-delivery check.
The incremental prerequisite is the complete v0.4.1 history rooted through the
base commit given above, not v0.4.0 or an arbitrary similarly named checkout.

## Version 0.4.1 - executed on 2026-11-17

Based on the clean v0.4.0 commit
`ecab7f3e0945be44ae17f3f7dd0bfd5de456d7f2`. This patch changes only the
Rack response body's `each` method to hold its serialized JSON String in an
iteration-local variable before testing/yielding it; `close` still clears its
instance-variable reference. The change introduces no lock, copy, background
work, global state or extra retention after `each` returns.

The new test deterministically forces `close` after a content-presence check
but before yielding. The prior implementation would yield `nil`; the new one
yields the same String and leaves `@content` cleared. Existing lifecycle and
concurrent-request isolation tests remain in place.

On Linux 6.18.57 / MRI Ruby 3.3.8, Minitest 5.20.0, the full standalone suite
passed **179 tests and 894 assertions, zero failures/errors/skips** on seeds
24680 and 43210. `ruby script/bundler_smoke` passed for both automatic and
explicit loading using Bundler 2.5.22. `gem build rails_runtime_info.gemspec`
produced a 0.4.1 gem. All Ruby source, tests, scripts and the gemspec passed
`ruby -c`; `git diff --check` passed.

No Rails application was booted, no runtime dependencies were installed, and
no external network/service calls were made. Rack::Lint remained unavailable
because Rack is not installed; `script/rack_lint` exited 2. Neither Ruby 2.4,
Ruby 3.4, Rails 5.1+, Passenger, nor Puma was exercised. The test simulates
the troublesome interleaving deterministically rather than stress-testing
an actual concurrent Rack server. Refer to the prior 0.4.0 entry for Linux
native-thread behavior and its untested deployment combinations.

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
