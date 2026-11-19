# Agent instructions

## Purpose

`rails_runtime_info` is an internal, on-demand, read-only diagnostic Rack
endpoint. The owner prioritizes non-interference with existing applications
above additional diagnostic coverage. Integration is Gemfile + one explicit
route. The output is for troubleshooting humans; a fixed JSON schema is not
required.

## Non-negotiable runtime constraints

- Target Ruby 2.5+ and Rails 5.1+. Guard optional APIs and keep source and test
  syntax compatible with Ruby 2.5.
- No Railtie, Engine, global middleware, initializer, route registration, hooks,
  instrumentation, monkey patches, persistent counters, caches or threads.
- Requiring the gem must define code only, load only its own implementation,
  and not boot Rails, read diagnostics, activate optional frameworks or connect
  anywhere. Request-time standard-library requires are allowed.
- No database/pool access, network connections, subprocesses, Gemfile/gemspec
  evaluation, lockfile reads, Bundler resolution, Rails::Info, Rails.application lazy creation,
  queue-adapter construction or autoloading of optional framework constants.
- No forced GC, compaction, GC tuning, YJIT enable/reset/statistics toggles,
  ObjectSpace traversal, signals, asynchronous timeouts or worker termination.
- Server counters are passive reads only: Passenger's current handler iteration
  and Puma::Server.current.requests_count. Do not synthesize or cache counts,
  scan other threads, acquire server locks, query control sockets, call
  passenger-status or use broader Puma stats APIs (which can reset metrics).
  Guard server constants without autoloading and respect dotted field exclusions
  before accessing readers. Accept only nonnegative Integers. Omit unavailable
  counters; isolate failed reads under their full errors paths. Do not conflate
  Passenger's per-thread iteration with process-wide completed requests or
  Puma's shared worker count with a unique request sequence number.
- Native-thread lifetime is a passive Linux observation only. Prefer a positive
  Integer from the optional Thread.current.native_thread_id and the matching
  /proc/self/task/<TID>/stat; after an ordinary failure try /proc/thread-self/stat
  once. Do not coerce invalid IDs, guess TID from PID/object_id/pthread_self,
  scan tasks or introduce Fiddle/native calls. Missing facilities are optional;
  unexpected unrecovered failures belong in the field's errors entry. Reuse the
  bounded stat parser/lifetime calculation, preserve TID if age calculation
  fails, and skip discovery when excluded. TID-only selection must not calculate
  age. Report native task age, not request duration or guaranteed Ruby Thread
  age under M:N scheduling. Never pin threads or retain Thread objects/baselines.
- Ruby thread inventory uses only core readers, bound rather than dispatched
  through application Thread instances. Skip Ruby-defined/prepended replacements;
  do not invoke inspect, join, value, wakeup, kill or locals. The legacy count
  uses the same guarded list. Cap inventory at 256 threads and names at 1024 bytes.
  Thread.list itself still enumerates all visible/current-Ractor Ruby threads;
  neither this nor VM work is guaranteed constant-time or allocation-free.
- Backtraces are opt-in via process.thread_backtraces, at most 64 threads,
  64 frames each, 1024 bytes per frame. Call the bounded core backtrace API once
  with one sentinel frame; never retry without bounds. No stack locals, native
  frame pointers, timers, thread-control operations or global caches. Isolate
  errors per field/thread; permit terminated threads. Keep only primitive
  copied metadata, never Thread, frame/location, reader or array references.
- Current-thread CPU time reuses stat fields 14/15 and SC_CLK_TCK, separately
  guarded from age and TID. No extra task-stat read, sampling interval or delta.
  CPU-only selection must not read uptime; TID-only skips CPU and age conversion.
- Process limits use only the existing bounded /proc/self/limits read. Replace
  raw contents with a map of snake_case resource names to soft/hard/units.
  Finite values are base-10 Integers, unlimited remains a string, and absent
  units are nil. Parse horizontal whitespace, not fixed offsets or 2+ spaces;
  full-width integers may have a single separator. Skip headers/malformed rows,
  accept additional resource names, retain no raw copy and add no getrlimit calls.
  Respect selection before reading and isolate ordinary file/parser failures.
- FD link details are opt-in via process.linux.fd_details; cap at 1024 entries
  plus one lookahead. Namespace links are default-on, capped at 64 plus one.
  Directory enumeration/readlink only; never open/follow/duplicate/use a target,
  inspect sockets, or add fdinfo. Bound link text to 4096 bytes. Isolate vanished
  or denied entries, tolerate reused FDs, close enumeration directories, and
  omit missing optional directories. Document process-view namespace scope.
- Namespace discovery must try Dir.foreach first. Only EACCES/EPERM triggers
  the frozen known-name fallback (cgroup, ipc, mnt, net, pid, pid_for_children,
  time, time_for_children, user, uts). Respect selection before each readlink;
  skip ordinary failed fallback probes without null/error entries, including
  missing old-kernel names. Fatal exceptions still propagate. Preserve normal
  enumeration/FD error handling. Report namespaces.discovery as "directory" or
  "known_names_fallback" when discovered; a discovery-only selector enumerates
  without reading links, whereas limit-only selection still skips discovery.
  Do not add a discovery field to FD details. An empty fallback means no
  selected readable links, not no namespaces; truncated=false is not proof of
  exhaustive discovery. Do not alter dumpability, permissions or namespace
  membership, or add open/stat/access checks of symlink targets.
- Keep cgroup resource usage/limits deferred in TODO.md. Preserve only the
  existing raw cgroup membership text; implement no snapshot-delta sampling.
- HTTP request headers and explicitly selected ENV values stay unredacted.
  Within request.rack_environment, allow only the documented action_dispatch
  keys; omit all others in that namespace, nested action_dispatch containers,
  and rack.session.options. Apply omissions before touching values, recursively
  through plain env containers. No selector, including all, may override this.
  Do not add arbitrary credential heuristics. Optional, explicit per-route
  Basic authentication is the only authentication feature; do not enable it
  globally or redact its incoming Authorization header.
- Keep Endpoint.basic_auth(htpasswd: path, realm: ...) opt-in and route-local.
  Route examples must use ENV["RAILS_RUNTIME_INFO_HTPASSWD"], never a raising
  ENV.fetch. Constructor performs no I/O/requires; nil/invalid configuration
  must produce a closed 503 endpoint, not prevent Rails startup or fall back
  to Endpoint.call. Do not evaluate arbitrary config Proc/Pathname hooks.
- Authentication supports only explicit {SSHA} and {PLAIN}; no bcrypt, apr1,
  crypt or unprefixed plaintext fallback. Strictly decode Basic credentials
  and SSHA Base64. Require nonempty credentials and an actual SSHA salt.
  Verify the whole bounded file: duplicates, malformed/unsupported entries or
  no entries invalidate it, including after a valid matching entry. Preserve
  documented whitespace and colon-comment semantics. Never truncate a large
  file into successful authentication.
- Read a regular password file only for a well-formed authentication attempt,
  without caching, subprocesses, external services or locks. No diagnostic
  collectors, query/body parsing or rack.input reads before successful auth.
  Use static 401/503 JSON for auth failures; never echo exception details or
  file contents and never log secrets. Fatal exceptions propagate. Do not
  mutate env or set REMOTE_USER. Shared wrapper state is immutable config only;
  credentials and parsed files must not be retained. No user sessions, rate
  limits or global interception. Digest comparisons visit all fixed-size bytes;
  do not promise whole-request constant timing or secure memory wiping.
- Optional sleep is query-only: exactly one form-decoded sleep value, unsigned
  ASCII decimal, 0..30 seconds inclusive, at most 64 decoded bytes. Reject
  duplicates, empty/malformed/signed/non-finite/excessive values with 400. Check
  the exact decimal upper bound before Float conversion. Do not coerce invalid
  values to zero or use Rack/Rails params. Unrelated values remain uninterpreted.
- Authenticate first when enabled; validate both what and sleep before any wait.
  Sleep once through Kernel.sleep only for positive seconds, before Snapshot
  construction/collection. Reuse the validated Selection, with no reparse after
  waiting. Invalid requests/auth failures must never wait, collect or read input.
  No default delay, sleep in Body, busy loop, timer, extra thread, lock, hooks,
  retries or scheduler changes. Add no sleep field to JSON. Preserve query echo,
  HEAD and existing response-body lifetime. Ordinary sleep failures use the
  existing 500 boundary; fatal exceptions propagate. Do not promise forced
  process rerouting, disconnect cancellation or exact elapsed time.
- The only gem inventory is Gem.loaded_specs; never read a lockfile or resolve
  dependencies. The default selection is exactly
  all,-loaded_features,-load_path,-gems,-environment,-request.body,
  -process.thread_backtraces,-process.linux.fd_details (one expression without
  whitespace). Apply user
  what rules left to right after that default. Bare names include; - excludes;
  explicit + remains accepted for compatibility. Preserve the documented
  nested/parent-reset semantics and standard query form decoding. Skip excluded
  collectors, especially request body reads; do not invoke Rack/Rails params.
  Default requests must not call the body collector, even for cached bodies.
- Output selected gc, yjit, runtime, application, request sections last, in that
  order. Keep sampling order independent of presentation order.
- Return at most 100 KiB of request-body bytes; read at most one extra byte for
  truncation detection. Prefer a bounded prefix of existing RAW_POST_DATA without
  reading input again. Do not duplicate body caches through the Rack environment.
  Never rewind, drain, close or parse `rack.input`.
- Unknown application objects must remain opaque. Do not invoke arbitrary
  inspect/to_s/to_h/as_json/to_json methods or traverse lazy container subclasses.
- Each collector must fail independently. Ordinary failures belong in `errors`;
  fatal exceptions must propagate. Never log request data or errors globally.
- Keep request and snapshot data short-lived. The response body retains only
  serialized JSON and releases it on close. `Body#each` must capture a local
  reference to the JSON before checking/yielding it, so concurrent `close`
  cannot cause a nil chunk; do not copy or retain it beyond iteration. Do not
  retain request objects in closures, class/module variables, thread locals
  or global error stores.

"Read-only" means no intentional application mutation, not zero allocation,
zero observer overhead, or a guarantee that RSS falls after a request. An
explicit sleep deliberately consumes request-serving capacity; document it as
an opt-in diagnostic side effect, not a passive observation. Preserve
this distinction in documentation.

## Development workflow

Use the existing checkout in the workspace and preserve unrelated edits. Run
the standalone suite from the repository root with an installed Ruby and
Minitest. It runs without Rails, Rack, or Bundler.

```sh
ruby script/test --seed 24680
ruby script/test --seed 43210
```

If Ruby is missing from `PATH`, check for the installed compatibility kit at
`/workspace/.rails-runtime-info/compat`. Its `ruby-env` selects an interpreter
and matching Bundler by exact version. The kit's `verify-ruby VERSION` runs
syntax checks, both seeds, Bundler, Rack::Lint, and a built-gem smoke test.
Use `verify-auth-ruby VERSION` for the focused authentication suite and
`verify-fixture TARGET` for installed Rails fixtures. Select fixture rows
from `targets.tsv` that meet the gem's Ruby requirement. Use `verify-server.py`
for loopback Puma and Passenger checks and `verify-yjit` or
`verify-dumpability` for the corresponding runtime checks. The kit is optional.

Without the kit, use `ruby script/rack_lint` with an installed Rack and
`ruby script/bundler_smoke` for the two local Bundler loading modes. Build from
a scratch directory containing a copy of the source when testing a package.

```sh
gem build rails_runtime_info.gemspec
```

Run local tests, builds, disposable Rails fixtures, and loopback servers as
part of development. Prefer installed runtimes and cached gems. When setup is
needed, use the environment's package access and keep dependencies isolated to
the project or test fixture. Use synthetic data and credentials. Reserve live
application and service access for tasks that authorize it.

Add focused regression tests for behavior changes. Test absent APIs, nil and
non-finite statistics, invalid strings, body boundaries, collector failures,
lazy objects, lack of persistent request retention and normal concurrent use.
Also test unavailable/raising server APIs, server autoload avoidance, counter
selection, concurrent handler/server reads and no server-object retention.
Test native-ID/task-path and thread-self fallbacks, unavailable/raising APIs,
invalid IDs, malformed stat files, denied/missing procfs, clock/uptime errors,
nested selection, independent failure handling and live native-thread reads
when supported. Simulating an old-kernel path is not proof of CentOS 6 testing.
Test permanent server-secret omissions, bare/signed/nested selector ordering,
query encoding, disabled collectors, and explicit/automatic require behavior.
The optional script/bundler_smoke uses installed Bundler and temporary local
path-gem Gemfiles only; it is not a Rails integration test.
Test optional authentication separately: no boot-time I/O/framework loads,
missing/invalid ENV/file/realm, both explicit formats, malformed/duplicate/
unsupported files, bounded strict parsing, HEAD/challenge behavior, preservation
of headers/env, no pre-auth collectors/body reads, file replacement, concurrent
first digest loading and credential isolation, fatal propagation, and request/
file lifetime. All test credentials must be synthetic.
Test bounded thread inventories/backtraces, dead/churning threads, singleton and
subclass overrides, global reader/list replacements, nil/missing APIs,
per-field errors, primitive-only retention, and concurrent diagnostics. Verify
expensive lists are default-off and skipped when excluded, including summary-only
selectors. Test CPU units, bad ticks and independent age failures; FD/namespace
limits, missing directories, readlink-only behavior, per-link races, nested
selection and descriptor cleanup. Keep synthetic tests distinct from live VM/
procfs tests; do not assert an atomic process-wide snapshot or hard VM deadline.
Test limits parsing with padded/compact/tab-separated rows, full-width integers,
unlimited values, missing units, unknown names, malformed lines and CRLF. Verify
structured-only JSON, bounded reads, nested selection, skipped/non-Linux reads,
independent ordinary failures and fatal propagation.
Test namespace directory-first discovery, EACCES/EPERM fallback, missing versus
unexpected directory errors, known/unknown names, partial/all failed probes,
bounded links, selected/excluded names, discovery-only and summary-only
requests, and fatal errors. Verify that namespace discovery is reported
accurately and that FD details do not gain a discovery field.
Keep simulated dumpability restrictions distinct from actual patched-Ruby runs.
Test delay boundaries/duplicates/encoding, auth-before-validation-before-sleep,
invalid-what rejection before waiting, zero/default no-op, no pre-wait snapshot
or body reads, all methods/HEAD, unchanged JSON, exceptions and cleanup. Include
concurrent delayed/no-delay requests and a small real fractional sleep. Tests
may use controlled stubs/barriers but must distinguish them from live servers.
Do not add live diagnostic output or real secrets to fixtures.

Update README and docs/VALIDATION.md when behavior or tested environments
change. Clearly separate supported targets from actually executed tests. Do
not claim Ruby/Rails version coverage that was not run.

## Repository and publication

Preserve the gem's private-publication safeguard and license. Use the checkout's
configured remote for authorized pushes and keep credentials out of files and
logs. Use a normal fast-forward push. When no upstream or target branch is
set, use a topic branch. Report remote access failures and keep local work intact.

Use the repository's commit identity unless the owner specifies another. If
needed, set it in this checkout:

```sh
git config user.email git.codex.91ndg9n33q@hodor.cz
```

```sh
git config user.name 'Jan Seda'
```

Create bundles when requested. For a full bundle, include all refs and history,
verify it, and restore it into an empty directory. For an incremental bundle,
exclude the agreed base commit and include the requested commit ref. Include
an annotated tag when delivering a tagged release. Restore an incremental
bundle in a separate checkout containing the base, verify and fast-forward it,
and compare the restored commit, tree, and any included tags to the source.
Run tests from the restored checkout and provide the SHA-256, prerequisite
commit, and fast-forward commands with the bundle.
