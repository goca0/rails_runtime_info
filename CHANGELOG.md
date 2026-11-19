# Changelog

## Unreleased

- Require Ruby 2.5 or newer.
- Stabilize weak-reference tests by ending fixture workers before collection
  and clearing the synthetic Puma server reference during fixture teardown.
- Allow CPU counters to advance between reads in the live native-thread test.

## 0.7.3

- Add `process.linux.namespaces.discovery` to distinguish successful directory
  enumeration (`"directory"`) from permission-denied known-name probing
  (`"known_names_fallback"`). The value describes the discovery method, not
  whether the namespace inventory is complete.
- Preserve readlink-only fallback behavior and non-invasive collection. A
  discovery-only selector enumerates the namespace directory without reading
  any links; limit-only selection continues to skip enumeration entirely.
  FD details are unchanged. Add focused selection, fallback and omission tests.
- Document executed v0.7.1/v0.7.2 Ruby validation, including the unprivileged
  `PR_SET_DUMPABLE=0` live test, and validate this release under Ruby 3.3.8.

## 0.7.2

- Keep Dir.foreach as the first namespace discovery method. If listing
  /proc/self/ns fails with EACCES or EPERM, try the ten known namespace symlink
  names with the existing bounded readlink helper. This supports environments
  where directory listing is denied but named readlink calls still work.
- Omit ordinary failed fallback probes, including namespace types missing on
  older kernels; preserve successful entries. Keep the existing output shape,
  selectors, normal-discovery/FD error reporting and fatal-exception behavior.
  No dumpability/permission changes, native calls, locks, caches or target opens.
- Document that fallback is a best-effort known-name inventory, including
  empty-result and truncated semantics. Add regression tests for discovery,
  permissions, selection, bounds and failures. Ruby execution remains unavailable
  in the release container; see docs/VALIDATION.md.

## 0.7.1

- Change process.linux.limits from raw /proc/self/limits text to a structured
  object keyed by snake_case resource names, with soft, hard and units fields.
  Finite limits are JSON integers, unlimited remains the string "unlimited",
  and omitted units become null. No raw copy is included anywhere in the output.
- Parse whitespace-separated value columns without assuming padding widths;
  handle 20-digit integers, compact/tab-separated rows and optional units.
  Skip headers and malformed rows without requiring a fixed resource list.
- Preserve the 64 KiB read bound, dotted selection, independent error handling
  and request-local state. Add focused regression tests and document this
  output-type change. Ruby execution was unavailable in the release container;
  see docs/VALIDATION.md for the exact validation limits.

## 0.7.0

- Add default-on bounded Ruby thread inventory with identity, status, name and
  available native TID. Bind core readers, bypass object/subclass overrides and
  skip replaced APIs. Reuse guarded enumeration for the existing thread count.
- Add opt-in backtraces (64 threads, 64 frames each, 1024-byte text prefixes);
  use only the bounded core API, with no unbounded fallback, locals or thread
  controls. Keep metadata/stack failures field-local and results request-local.
- Add current-native-thread cumulative user/system CPU seconds using the existing
  stat read, with conversion independent of lifetime and TID. Preserve old-kernel
  discovery/fallbacks and TID-only no-clock behavior.
- Add opt-in bounded FD symlink details and default-on namespace link IDs. Use
  readlink only, isolate vanished/denied entries, report truncation, and never
  open or operate on link targets. No new dependencies, locks, hooks or caches.
- Extend defaults to exclude process.thread_backtraces and process.linux.fd_details.
  Existing left-to-right parent-reset semantics apply, including all/process.
  Preserve body omission, authentication/delay ordering and display order.
- Defer structured cgroup limits/usage in packaged TODO.md; existing raw
  membership output stays unchanged. Do not implement snapshot deltas.
- Add regression tests and live thread/procfs checks; document bounds, VM cost,
  Ractor/M:N scope, namespace scope, stale observations and validation gaps.

## 0.6.0

- Add optional query-only sleep in seconds, default zero and capped at 30.
  Accept unsigned decimal integers/fractions; reject duplicate, malformed,
  signed, non-finite and excessive values with 400 invalid_sleep. Bound the
  value length and check the exact decimal limit before float conversion.
- Authenticate first, validate both what and sleep, then wait once before
  snapshot construction. Invalid requests do not wait or collect; zero/absent
  sleep never calls Kernel.sleep. Reuse the already-validated selection.
- Preserve default selection, body omission, auth behavior, query echo and JSON
  fields. Do not add request.sleep_seconds. No persistent state, timers, locks,
  extra threads, busy waits or changes to unrelated routes.
- Add validation, ordering, authentication, concurrency, memory-lifetime and
  fractional-wait tests; document capacity/routing, fiber-scheduler, timeout and
  disconnect limitations. Extend standalone Bundler and optional Rack checks.

## 0.5.0

- Add opt-in Endpoint.basic_auth(htpasswd: path, realm: ...) returning a
  Rack-compatible per-route wrapper; original endpoint behavior stays unchanged.
- Support multiple users with explicit RFC2307-style {SSHA} and {PLAIN} entries,
  comments and LF/CRLF. No bcrypt, apr1, crypt or extra gem dependencies.
- Use ENV[...] in route examples. Missing/invalid configuration creates a closed
  503 endpoint without file I/O or digest loading during Rails initialization.
- Strictly bound/decode Basic credentials and password-file contents. Reject
  duplicate users, malformed/unsupported entries, empty passwords and unsalted
  SSHA. Reread the entire small regular file for each valid credential attempt;
  use fixed-size digest comparisons and retain no auth request state or cache.
- Return generic no-store 401/503 responses before diagnostics on auth failure;
  never log secrets or expose verifier details. Preserve the original headers,
  including Authorization, and do not mutate env or set REMOTE_USER.
- Add standalone format, failure, boot/lifetime, file-replacement, first-load and
  concurrency tests; extend optional Bundler/Rack smoke scripts and documentation.

## 0.4.1

- Hold the response JSON string in an `each`-local reference before checking
  and yielding it. A concurrent `Body#close` can no longer turn an already
  selected response chunk into `nil`. No copies, locks or retained references
  beyond the executing iteration are introduced.
- Add a deterministic regression test for `close` between the presence check
  and the yield. Preserve the existing on-close release and request-local
  garbage-collection behavior.

## 0.4.0

- Add optional process.linux.current_thread.tid and current_thread.lifetime.
  Prefer Thread.current.native_thread_id plus /proc/self/task/<TID>/stat;
  fall back to /proc/thread-self/stat after unavailable APIs or failed reads.
  The task-directory path supports older kernels without thread-self.
- Reuse the existing bounded process-stat parser and lifetime calculation.
  Reject mismatched IDs and invalid numerical values; omit missing facilities
  and isolate unexpected failures. Keep TID when only age calculation fails.
- Respect nested selectors before discovery; TID-only selection skips age
  calculation. No new hooks, thread scans, native bindings, dependencies,
  caches, thread-local state, locks or server-specific behavior.
- Add standalone fallback/error/selection tests and live Linux native-thread
  checks. Document M:N limitations and untested CentOS 6/Ruby 3.4 execution.
  Existing process-age fields, default selection, response ordering and
  server counters are retained. Full/incremental bundles use v0.3.0 as base.

## 0.3.0

- Add optional server.passenger.thread_iteration from the current Passenger Ruby
  thread handler and server.puma.requests_count from Puma::Server.current.
  These report existing counters only; no instrumentation, hooks, initialization,
  server locks, subprocesses, control-socket queries or statistics resets.
- Skip counter discovery/readers when their dotted selector paths are excluded.
  Omit unavailable or invalid readings; isolate exceptions per counter while
  retaining unrelated diagnostics. Keep existing defaults and display order.
- Document Passenger's per-handler iteration versus Puma's shared worker count,
  concurrency/fiber limitations and the distinction from passenger-status.
- Add standalone regression tests for optional APIs, errors, autoload avoidance,
  selectors, multithreaded snapshots and server-object lifetime. Bump to 0.3.0
  and document full/incremental bundle restoration from v0.2.1.

## 0.2.1

- Accept bare category and dotted-path names as inclusion rules; `-` still
  excludes. Explicit `+` remains accepted for compatibility. Plain `what` URLs
  no longer require percent-encoded plus signs.
- Add `-request.body` to the default selection. Default diagnostics do not call
  the body collector or read rack.input. Select request.body, request or all
  to restore bounded body capture; later exclusions still take precedence.
- Update examples, agent guidance and regression tests for the new defaults,
  unsigned selectors, legacy signed queries and cached-body omission.

## 0.2.0

- Remove the Gemfile.lock inventory and all lockfile-reading code; retain only
  activated gems from Gem.loaded_specs.
- Omit non-whitelisted action_dispatch request-environment keys, including
  secret_key_base, legacy secret_token, key generators and cookie rotations.
  Also omit rack.session.options, which can contain signing secrets.
- Add ordered, signed `what` selection with nested JSON-object paths. Defaults
  exclude loaded_features, load_path, gems and environment; excluded collectors
  do not run. Secret omissions cannot be overridden by selectors.
- End displayed output with gc, yjit, runtime, application and request without
  moving GC/YJIT sampling later.
- Document explicit require in routes and Bundler's automatic-loading behavior.
- Add regression tests for selection, secret exclusions, non-interference and
  an optional local-only Bundler loading smoke test.

## 0.1.0

Initial implementation: standalone Rack endpoint, bounded request-body capture,
full request headers/environment, activated and locked gem inventories,
best-effort Rails/runtime/GC/YJIT/Linux collectors, defensive serialization,
and no automatic Rails integration or service connections.
