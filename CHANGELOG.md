# Changelog

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
