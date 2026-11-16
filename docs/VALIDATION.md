# Validation record

## Version 0.3.0 - executed on 2026-11-16

Environment: Linux x86_64, MRI Ruby 3.3.8, Minitest 5.20.0, JSON 2.7.2,
RubyGems 3.6.7 and Bundler 2.5.22. No Rails application was booted. Rails,
Rack, Passenger and Puma are not installed in the validation environment.

Development started from the supplied v0.2.1 full bundle at
`cc232579f416ca4edb872c065b058ae542003a81`. Its unchanged baseline passed with
120 tests and 516 assertions. Previous commits and annotated tags are retained.

The 0.3.0 standalone suite passed with **147 tests, 736 assertions, zero
failures, zero errors and zero skips**, with seeds 24680 and 43210:

```sh
ruby script/test --seed 24680
```

```sh
ruby script/test --seed 43210
```

These tests require neither Rails nor Rack nor Bundler. Passenger and Puma
counter tests use synthetic API objects; they do not start either server.

## New regression coverage

- Passenger current-handler iteration and Puma current-server request count,
  including zero and large Integers. Missing handlers, methods and constants,
  nil values, negatives, non-Integers and opaque unexpected objects are omitted
  without coercion or object serialization.
- Server-module and Puma::Server autoloads remain unresolved. No server is
  required, instantiated or configured. Existing require-time isolation tests
  also confirm no extra gem activation, threads, ENV or load-path changes.
- Exceptions in either counter, Puma::Server.current discovery and capability checks
  are isolated. StandardError, LoadError and NotImplementedError produce
  field-local errors; fatal exceptions propagate. Other server/process fields
  still work when one reader fails.
- Dotted counter inclusions/exclusions skip discovery and reader calls; parent
  resets preserve existing selection semantics. Default counter inclusion
  does not change body omission or the required top-level presentation order.
- Frozen synthetic handlers/servers can be observed without mutation. Repeated
  snapshots do not increment or cache readings. No server mutex or broad Puma
  stats method is called, and no thread-local key is installed by the collector.
- Concurrent synthetic requests retain their individual Passenger iterations
  while observing the shared synthetic Puma worker count. A different fiber
  without Passenger's local entry produces no counter rather than a fallback
  thread/fiber search. This tests collector behavior, not live server scheduling.
- Weak references verify the completed response does not retain the temporary
  handler or server. Forced GC is used only in tests, never by library code.
- The implementation and gemspec both report version 0.3.0.

Previous coverage remains for request metadata, UTF-8/binary handling, the
100 KiB body limit, cached bodies, selector ordering/parser limits, permanent
server-secret omissions, untouched default input streams, full GC/YJIT hashes,
optional frameworks, failed collectors, error/JSON fallbacks, HEAD, concurrent
requests, Linux /proc readers and response closure. Secret fixtures are synthetic.

## Other executed checks

- All 26 Ruby library/test files, gemspec/Gemfile/Rakefile and executable scripts
  passed `ruby -c` under Ruby 3.3.8. This is not a Ruby 2.4 parser check.
- `gem build rails_runtime_info.gemspec` succeeds. The deliberately unspecified
  homepage produces a warning; no runtime dependencies were added.
- The built gem was extracted into a temporary directory and its library loaded
  in a fresh Ruby subprocess. Both counter paths, missing-counter behavior,
  version, response status/length and body closure passed there. This used only
  synthetic server APIs, without installing any gems.
- `ruby script/bundler_smoke` passes with installed Bundler 2.5.22 for automatic
  Bundler.require loading and explicit require with require: false. Temporary
  Gemfiles use only the local path gem. Bundler does normal local resolution
  and may create a temporary lockfile; the diagnostic endpoint never reads it.
  Its no-global-source warning is expected. No dependency installation or
  remote dependency source was used.
- `git diff --check` passes.
- Passenger stable-6.0 handler source and the official Puma 5.6.9/8.0.2 source
  documentation were reviewed for counter semantics. References are in
  docs/DESIGN.md. Source inspection does not certify runtime compatibility.

## Explicitly not executed

**Actual Rails, Passenger or Puma integration and Ruby 2.4/2.5 execution have
not been tested.** Ruby 2.4+ and Rails 5.1+ remain implementation targets,
not verified version coverage. Neither synthetic framework objects nor source
inspection substitutes for testing a deployed application/server combination.
Passenger Enterprise's private internals were not inspected or run.

`script/rack_lint` reports Rack unavailable and exits 2. No actual Rack 2/3
lint run is claimed. No packages were installed to obtain those environments.

No real enabled-YJIT instance, non-Linux host, ingress Basic authentication
configuration or deployed middleware chain was exercised. No database,
external-service or control-socket checks were performed.

## Deployment acceptance checks still needed

In an authorized test environment, use the existing explicit require and route.
Request `?what=-all,server,errors` through the protected ingress. Confirm the
appropriate counter appears for the actual Passenger/Puma version, or is
omitted without breaking the response when the API is unavailable. Confirm
ordinary application requests still work and that excluding each counter
prevents its reader from being called. Do not assume an exact process-wide
request ordinal, successful completion count or equivalence to passenger-status.

Retain prior checks for default body omission, bounded opt-in body capture,
request ID visibility and forbidden framework-key omissions. Verify alternate
ingress/backend paths cannot reach the endpoint without protection, and keep
appropriate proxy body/time/concurrency limits.

Do not commit live output: HTTP credentials and explicitly requested ENV still
contain secrets. Test older runtimes and real Rails/server versions before
claiming their compatibility. This record is bounded evidence, not a guarantee
against arbitrary monkey patches, blocking replacement readers, fatal VM
failures or resource exhaustion. Earlier validation records remain in Git
history and the v0.1.0, v0.2.0 and v0.2.1 tags.
