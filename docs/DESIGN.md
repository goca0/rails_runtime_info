# Design notes

## Public surface

The only integration API is `RailsRuntimeInfo::Endpoint.call(env)`. It returns a
Rack status/header/body tuple. Route selection and authorization are entirely
outside the gem. The endpoint can also be called without Rails present.
`RailsRuntimeInfo::VERSION` identifies the implementation; JSON structure is
not promised stable.

## Implementation layout

| Component | Responsibility |
| --- | --- |
| `endpoint.rb` | Deferred JSON require, top-level ordinary-failure fallback, Rack headers and HEAD handling. |
| `body.rb` | Enumerable Rack body retaining only serialized JSON; idempotent release on close. |
| `snapshot.rb` | Request-local orchestration, per-field and per-section exception boundaries, framework/runtime observation. |
| `normalizer.rb` | Copies safe primitives, guards traversal, avoids application serialization hooks and represents unsupported/binary/non-finite data. |
| `request_info.rb` | Raw request metadata, reconstructed headers/URL and bounded body capture. |
| `linux_process.rb` | Bounded /proc readers and limited parsing; no subprocesses or native bindings. |
| `selection.rb` | Request-local signed selection tree, narrow query parsing, collection guards and in-place JSON projection. |
| `support.rb` | Non-autoloading constant lookup, class labels, UTC formatting and bounded regular-file reads. |

Known Rack body caches are descriptors in the environment snapshot, not
second copies of an unbounded body. Rails parameter caches are omitted by the
Action Dispatch whitelist. Existing RAW_POST_DATA is used only through
a bounded prefix. Other input streams are read at most 100 KiB plus one byte.

No request context reaches a class-level cache. `Snapshot` and its referenced
request and selection tree become unreachable after serialization returns. `Body` stores no block,
normalizer, snapshot or request, and drops the JSON reference on `close`.

## Rails is optional, and initialization is deliberately avoided

Calling `Rails.application` can instantiate the application's singleton.
Calling `Rails.root`/`Rails.configuration` can reach that same path. To avoid
creating anything in an unusual partially initialized environment, the Rails
collector reads only an existing `Rails.@application`, its existing `@config`,
and the existing cached `Rails.@_env`. Absence is reported rather than forcing
initialization. These private storage details are a small, isolated compatibility
risk; a changed Rails implementation should result in less information, not
fallback to lazy creation. Access to selected configuration readers is guarded
and exception-isolated.

The existing cache object contributes its class name only. The job adapter is
read from configuration, never instantiated through ActiveJob. ActiveRecord is
not referenced by library code at all. Optional constants are not resolved when
they are registered as autoloads. Existing Passenger/Puma state is read only
through the narrow optional counter paths below; there are no fork hooks or
gem-maintained request counters.

## Passive Passenger and Puma counters

The existing server section gains two independent optional field captures:
`server.passenger.thread_iteration` and `server.puma.requests_count`.
`optional_server_counter` checks the full selector path before discovery or
reading, accepts only a nonnegative Integer, and omits unavailable readings.
Failures use the existing field-local null/error representation. The captured
result contains only an integer, never a handler/server object or exception.

Passenger discovery is precisely `Thread.current[:passenger_thread_handler]`;
only a present object's public `iteration` reader is called. Passenger's Ruby
handler installs that entry and increments its iteration before dispatching to
the Rack application. The loop also handles PING, out-of-band work and invalid
connections. This is per-handler progress, including the current iteration,
not the core's process-wide session-closure count shown by `passenger-status`.
Do not subtract one, combine threads, infer successful completion, or attempt
to reproduce the core's accounting. Ruby's `Thread#[]` storage is fiber-local;
if the endpoint executes elsewhere, an absent handler is acceptable. No private
instance-variable traversal, object-heap traversal, mutex or thread scan is used.

Puma discovery first checks for an already-loaded `Puma` and `Puma::Server`,
without resolving autoloads. The collector calls `Server.current` only when
supported and reads `requests_count` only from its non-nil result with a public
reader. No server is instantiated and there is no fallback to global stats or
control APIs. The counter is worker/server-wide and incremented before Rack
application dispatch in the inspected implementations. Several concurrent
requests can observe the same value. It is not an exact ordinal of the current
request or a count of completed successful application requests.

In particular, never replace these reads with `Puma.stats`, `Puma.stats_hash`
or `Server#stats`: broader stats calls can reset high-water metrics. Never
require Passenger/Puma, invoke `passenger-status`, query the core socket,
install instrumentation, or retain server/handler objects. Availability checks
and exception isolation provide best-effort compatibility, not a safety promise
against arbitrary monkey patches, a blocking replacement reader or fatal VM
failures. Ordinary exceptions are isolated; fatal exceptions still propagate.

## Error policy

Field captures include normalization inside their exception boundary. Section
assembly also has an ordinary-error boundary, so a future programming mistake
in one section should not suppress unrelated information. Successful sections
are not normalized a second time, avoiding a redundant large copy.

Handled optional failures are `StandardError`, `LoadError` and
`NotImplementedError`. The latter two are explicitly named because they are not
StandardError subclasses. Never rescue `Exception` wholesale. Exceptions and
backtraces are not stored; only class-name and normalized message data are
returned. Failure formatting has its own fallback.

The last-resort JSON response is a constant literal so a broken or missing JSON
serializer cannot recursively break its own error handler. It uses status 500.
A partial successful diagnostic snapshot uses 200, even when some collectors
failed. Invalid `what` uses 400 before collectors run. JSON generation of that
error is also inside the last-resort boundary. No status asserts application
health. The `errors` category can be explicitly deselected like any other key.

## Selection and display order

Selection is a request-local tree whose nodes contain an optional boolean and
child rules. A parent assignment clears its prior child rules; descendants
inherit the nearest assigned boolean. This gives left-to-right semantics without
keeping snapshots, query objects or a global rule cache. `all` assigns the root.
The starting expression is applied first, followed by user rules. Bare names
include, a leading minus excludes, and an optional plus is accepted for older
clients. Defaults exclude loaded_features, load_path, gems, environment and
request.body. Selecting request or all later restores body capture because a
parent assignment clears earlier descendant rules. Unknown nested names are
allowed because the output is intentionally not a fixed schema.

Only exact form-decoded `what` keys are used. URI decoding is loaded on demand;
no request parameter object is constructed. Bare names need no plus-sign
encoding; legacy encoded plus signs remain valid. Literal plus signs decode to
spaces, which are permitted around tokens. Repeated values retain wire order.
Selector size/count/depth limits bound tree growth. Unrelated query values are never decoded.

Top-level sections and independently collected fields consult the selection
before evaluating their blocks. In particular a disabled body is never read;
by default the body collector is not invoked even when Rails has cached it.
Projection prunes only the owned, normalized JSON hashes in place; it never
mutates source application hashes. Arrays/scalars are leaves. Flat dotted Rack
keys participate in the selector path without being restructured in output.
A leaf selection may still need its whole parent API (such as GC.stat).

GC/YJIT are still sampled before the large collectors. After projection, a
small top-level hash is assembled in documented display order, ending in gc,
yjit, runtime, application, request. This reuses section references, not copies
of their contents. The locked-gem collector, parser and lookup logic are removed.

## Permanent request-environment omissions

Rack env is not only HTTP input: Rails inserts application configuration and
cryptographic material. In `Normalizer`, request-environment mode checks keys
before visiting values. Only six documented `action_dispatch.*` keys pass:
request ID, existing remote-IP value, original path, path parameters, and the
two exception-display flags. The check applies recursively to plain containers;
it also handles symbol keys and omits a nested `action_dispatch` container.
Future/unknown namespace keys fail closed. No selector can restore an omission.

The important excluded keys are `action_dispatch.secret_key_base`, the Rails
5.1-era `action_dispatch.secret_token`, `action_dispatch.key_generator` and
`action_dispatch.cookies_rotations`. Cookie rotations can hold actual prior
signing/encryption keys. Cookie salts/digests and other framework configuration
are excluded as non-whitelisted metadata, without claiming salts are themselves
secret keys. Opaque application objects are never inspected for internal keys.

A second concrete secret-bearing location is `rack.session.options`:
Rack 2's Cookie passes its secret/old_secret options to Persisted, which copies
those options into the request env. The whole entry is omitted. HTTP header
values and explicitly selected ENV remain unfiltered as requested; this is not
a general secret scanner. Custom aliases or process ENV can still contain the
same secret. These limitations are stated in README rather than hidden behind
an absolute no-secrets claim.

## Serialization policy

Strings are copied into plain Strings. Valid UTF-8 bytes are returned as text;
otherwise a Base64 descriptor preserves the original bytes and encoding label.
Opaque objects are represented by a class-name descriptor. Hash and Array
subclasses are not traversed because their methods can perform lazy work.
Ordinary Hash/Array cycles, depth and traversal limits are represented explicitly.

Standard symbol/integer keys become JSON keys. Binary keys, non-primitive keys
and key collisions become a tagged entries list, not silently overwritten data.
NaN/Infinity retain their meanings in tagged objects rather than being emitted
as non-standard JSON tokens or replaced with zero/null.

The complete available GC/YJIT hashes are retained subject to the same defensive
normalization bounds. Counters are not assumed to have the same names across
Ruby releases, and missing counters never imply a negative result. No attempt
is made to infer a `yjit_used` boolean from an absent counter.

## Operating-system observations

Known local files are opened read-only with a bounded read and closed using a
block. Nonblocking open plus fstat rejects FIFOs/devices/directories for these
readers. This does not provide a deadline for regular filesystem operations or
kernel-generated /proc data. Request input is also not subject to a Ruby-level
timeout; asynchronous exceptions would undermine the non-invasive constraint.

The lifetime calculation parses field 22 of `/proc/self/stat`, taking account
of spaces/parentheses in comm, obtains clock ticks via `Etc.sysconf`, and compares
with `/proc/uptime`. It reports an approximate wall-clock start time. It is
independent of preloader state and gem load time. No shell `getconf`, `ps`,
`passenger-status`, uname or allocator-native call is executed.

There is no full smaps fallback when smaps_rollup is unavailable. `/proc/self/maps`
is scanned only for allocator-library names; it is not returned wholesale and
cannot identify statically linked allocators or prove active allocation routing.

## Upstream references consulted

These references explain the underlying interfaces; they do not substitute for
running a compatibility matrix. The implementation is original and does not
vendor Rails, Rack, Bundler or Ruby sources.

- Rails 5.1 Rack routes: https://guides.rubyonrails.org/v5.1/routing.html#routing-to-rack-applications
- Rails 5.1.7 application/environment accessors: https://github.com/rails/rails/blob/v5.1.7/railties/lib/rails.rb
- Rack 3.2 specification: https://rack.github.io/rack/3.2/SPEC_rdoc.html
- Ruby 2.4 Etc: https://docs.ruby-lang.org/en/2.4.0/Etc.html
- Ruby YJIT observation APIs: https://docs.ruby-lang.org/en/3.3/RubyVM/YJIT.html
- Linux proc documentation: https://docs.kernel.org/filesystems/proc.html
- Rails 5.1.7 env_config (legacy secret_token): https://github.com/rails/rails/blob/v5.1.7/railties/lib/rails/application.rb
- Rails 7.1.5.2 env_config (server keys and cookie rotations): https://github.com/rails/rails/blob/v7.1.5.2/railties/lib/rails/application.rb
- Rails cookie rotation key use: https://github.com/rails/rails/blob/v7.1.5.2/actionpack/lib/action_dispatch/middleware/cookies.rb
- Rails original_path and original_request_method: https://github.com/rails/rails/blob/v7.1.5.2/actionpack/lib/action_dispatch/middleware/show_exceptions.rb
- Rack 2.2.8 cookie secret options: https://github.com/rack/rack/blob/v2.2.8/lib/rack/session/cookie.rb
- Rack 2.2.8 per-request session options: https://github.com/rack/rack/blob/v2.2.8/lib/rack/session/abstract/id.rb
- Bundler setup versus require: https://github.com/rubygems/rubygems/blob/v3.5.22/bundler/lib/bundler/runtime.rb
- URI form-decoding semantics: https://docs.ruby-lang.org/en/3.0/URI.html#method-c-decode_www_form_component

Server-counter references checked for 0.3.0 (source inspection, not live-server
validation):

- Passenger handler storage and iteration: https://github.com/phusion/passenger/blob/stable-6.0/src/ruby_supportlib/phusion_passenger/request_handler/thread_handler.rb
- Puma 5.6.9 Server.current, requests_count and process_client: https://puma.io/puma5/Puma/Server.html
- Puma 8.0.2 Server.current, requests_count, process_client and stats: https://puma.io/puma/Puma/Server.html

These sources document counter semantics, not a certified version support
matrix. Server integration remains conditional on the APIs being present.
