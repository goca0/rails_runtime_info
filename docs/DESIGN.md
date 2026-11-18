# Design notes

## Public surface

`RailsRuntimeInfo::Endpoint.call(env)` returns a Rack status/header/body tuple.
Route selection remains outside the gem. Version 0.5.0 adds the explicit factory
`Endpoint.basic_auth(htpasswd: path, realm: "Rails Runtime Info")`, returning a
protected Rack callable; the original endpoint remains unauthenticated. Both
forms work without Rails present.
`RailsRuntimeInfo::VERSION` identifies the implementation; JSON structure is
not promised stable.

## Implementation layout

| Component | Responsibility |
| --- | --- |
| `endpoint.rb` | Deferred JSON require, validation-before-delay-before-snapshot orchestration, ordinary-failure fallback, Rack headers and HEAD handling. |
| `basic_auth.rb` | Immutable opt-in route wrapper, strict bounded Basic parsing, generic fail-closed responses and authentication-before-collection. |
| `htpasswd.rb` | Request-local bounded password-file validation and SSHA/PLAIN verification; no cache or non-stdlib dependencies. |
| `body.rb` | Enumerable Rack body retaining only serialized JSON; idempotent release on close. |
| `snapshot.rb` | Request-local orchestration, per-field and per-section exception boundaries, framework/runtime observation. |
| `normalizer.rb` | Copies safe primitives, guards traversal, avoids application serialization hooks and represents unsupported/binary/non-finite data. |
| `request_info.rb` | Raw request metadata, reconstructed headers/URL and bounded body capture. |
| `linux_process.rb` | Bounded /proc readers, CPU/lifetime parsing, bounded descriptor/namespace names and readlink; no target operations, subprocesses or native bindings. |
| `thread_info.rb` | Guarded core thread enumeration/readers and bounded metadata/backtrace prefixes; no controls, locals or persistent references. |
| `request_delay.rb` | Stateless, bounded, query-only delay validation; no waiting or collection. |
| `selection.rb` | Request-local signed selection tree, narrow query parsing, collection guards and in-place JSON projection. |
| `support.rb` | Non-autoloading constant lookup, class labels, UTC formatting and bounded regular-file reads. |

Known Rack body caches are descriptors in the environment snapshot, not
second copies of an unbounded body. Rails parameter caches are omitted by the
Action Dispatch whitelist. Existing RAW_POST_DATA is used only through
a bounded prefix. Other input streams are read at most 100 KiB plus one byte.

No request context reaches a class-level cache. `Snapshot` and its referenced
request and selection tree become unreachable after serialization returns. `Body` stores no block,
normalizer, snapshot or request, and drops the JSON reference on `close`.
`Body#each` snapshots the JSON String reference into a local before the nil
check and yield, preventing concurrent `close` from turning a yielded chunk
into `nil`. The local does not copy the String and expires when iteration ends.

## Optional route-local Basic authentication (0.5.0)

The explicit factory is the only activation point. No middleware is inserted
into Rails. A small Rack-compatible wrapper is used instead of constructing
Rack::Auth::Basic: it preserves the no-Rack dependency, avoids REMOTE_USER/env
mutation, bounds and strictly validates credential input, and has consistent
fail-closed behavior across targeted Rack versions. It is not a general-purpose
authentication framework.

Construction copies/freezes path and challenge strings and freezes the wrapper.
It performs no requires or file reads and stores neither ENV nor a Proc to resolve
it later. Invalid/missing config creates a disabled protected endpoint (503).
The documented `ENV[...]` expression cannot raise for a missing variable;
`ENV.fetch(...)` would raise before the factory receives its arguments and is
therefore explicitly prohibited in examples. Dotenv itself is not loaded.

On a request, missing/malformed credentials give 401 before any file I/O. Only
HTTP_AUTHORIZATION is accepted, with case-insensitive Basic and strict Base64
via Ruby's m0 unpack directive. Decoded credentials split at the first colon;
empty fields and ASCII control characters are rejected. Header size is capped
at 16 KiB. No header normalization, request query parsing, body read or
application callback is needed to authenticate. HEAD/OPTIONS are not bypasses.

Htpasswd.verify uses the existing bounded regular-file reader (64 KiB plus one
sentinel byte) and parses the entire local byte string before accepting a
match. Missing files, unsupported/invalid entries, duplicate names or an empty
user set are errors, never access grants. Comments and LF/CRLF are supported;
a colon after the encoded password starts the optional comment. PLAIN therefore
cannot encode a literal colon password, but SSHA can. Unknown hash formats are
not delegated to crypt, commands or other gems. The strict decoder requires a
20-byte SHA-1 result followed by nonempty salt bytes. For PLAIN, both candidates
are SHA-256 hashed before fixed-size comparison. Only the selected account's
digest is computed. Comparisons do not short-circuit at an unequal byte; the
whole authentication operation is not claimed constant-time.

Digest implementation files are explicitly required at request time (sha1 or
sha2), avoiding reliance on Digest constant autoload during simultaneous first
requests. Shared auth objects have no mutable request state. Parsed entries and
decoded credentials exist only in a checking method frame, which returns before
Endpoint.call; the response retains neither. There is no cache of successful
logins, password files, users, digests, ENV or exceptions. File edits take effect
on a subsequent valid attempt; advise atomic replacement, not partial in-place
edits. A filesystem can still block; do not add asynchronous timeouts or locks.

Ordinary auth failures, including LoadError and NotImplementedError, give a
static 503 JSON response, with no exception details or log calls. Credential
rejections give static 401 JSON plus a quoted/escaped realm challenge. Both are
no-store and honor HEAD. Fatal exceptions propagate. Auth exception handling
does not encompass successful downstream Endpoint.call; its existing error
policy remains responsible for collectors/serialization. Query selectors cannot
bypass auth, and failing auth never invokes selectors or diagnostics. Original
headers stay unfiltered, including the accepted Authorization value, by the
owner's explicit request. No REMOTE_USER assignment occurs.

The wrapper cannot protect an alternate unwrapped route, another server path,
or application data accessed elsewhere. TLS, filesystem permissions and network
restrictions remain the operator's responsibility. SSHA/PLAIN are compatibility
choices, not a recommendation for modern password storage. Tests are standalone
and do not claim nginx, Rails or Puma integration validation.

## Optional request delay (0.6.0)

Endpoint, not the response body or authentication wrapper, owns the delay.
An opted-in BasicAuth wrapper must authenticate successfully before calling it.
Endpoint constructs the Selection, parses RequestDelay.seconds, and calls
Kernel.sleep once only for a positive value. Only then does it construct a
Snapshot with the already-validated selection and collect/serialize diagnostics.
Standalone Snapshot callers may still omit the selection argument; the endpoint
never reparses what after sleeping. Invalid what wins if both controls are bad.

RequestDelay scans only QUERY_STRING using the same ampersand/form-decoding
convention as Selection. A separate small parser keeps existing what behavior
unchanged; no generic Rack/Rails params or request-body parser is introduced.
It returns zero when absent. Exactly one sleep value is permitted; an encoded
key is equivalent to its literal spelling. Unrelated values are ignored.

Accepted values match `[0-9]+(?:\.[0-9]+)?` in full, are at most 64 decoded bytes
(192 encoded bytes as an initial bound), and lie in 0..30 seconds inclusive.
Empty, signed, whitespace-padded, exponent and non-finite forms are rejected.
The integer part and any nonzero fractional part at 30 are checked before float
conversion, avoiding acceptance of an out-of-range decimal rounded down to 30.
A valid bounded decimal cannot overflow to infinity. No eval, external gem,
BigDecimal activation, global configuration or permissive to_f parsing is used.

RequestDelay::Invalid produces static-shape 400 JSON with error invalid_sleep
and an explanatory message containing no supplied value. Both validation error
paths return before sleeping, Snapshot construction, collector calls or input
reads. Sleep failures fall through the existing ordinary 500 boundary; fatal
exceptions propagate. No ensure clause introduces an extra or delayed sleep.
Neither Body#each nor Body#close waits. The response schema has no added sleep
field; the raw query echo is unchanged.

The ordinary Kernel.sleep operation intentionally occupies a request slot but
releases execution to other work. It is not a guarantee of process-wide
occupancy, another PID, exactly measured elapsed time, or a complete timeout
budget. Fiber schedulers can supply cooperative sleep. No server locks, busy
loop, instrumentation, thread creation, wakeup retry, connection watcher or
scheduler override is used. The caller's env and small selection stay live
while waiting; diagnostics and response JSON are allocated afterward. All delay
state is request-local and expires with the request, with normal GC semantics.

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
failed. Invalid `what` or `sleep` uses 400 before waiting or collectors run. JSON generation of that
error is also inside the last-resort boundary. No status asserts application
health. The `errors` category can be explicitly deselected like any other key.

## Selection and display order

Selection is a request-local tree whose nodes contain an optional boolean and
child rules. A parent assignment clears its prior child rules; descendants
inherit the nearest assigned boolean. This gives left-to-right semantics without
keeping snapshots, query objects or a global rule cache. `all` assigns the root.
The starting expression is applied first, followed by user rules. Bare names
include, a leading minus excludes, and an optional plus is accepted for older
clients. Defaults exclude loaded_features, load_path, gems, environment, request.body,
process.thread_backtraces and process.linux.fd_details. Selecting process or all
restores the expensive process lists. Selecting request or all later restores
body capture because a
parent assignment clears earlier descendant rules. Unknown nested names are
allowed because the output is intentionally not a fixed schema.

Only exact form-decoded `what` keys are used. URI decoding is loaded on demand;
no request parameter object is constructed. Bare names need no plus-sign
encoding; legacy encoded plus signs remain valid. Literal plus signs decode to
spaces, which are permitted around tokens. Repeated values retain wire order.
Selector size/count/depth limits bound tree growth. This parser never decodes
unrelated query values; sleep is handled separately by RequestDelay.

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

### Current native-thread lifetime (0.4.0)

`LinuxProcess.current_thread_stat` first calls the guarded
`Thread.current.native_thread_id` reader and, for a positive Integer, opens
`/proc/self/task/<TID>/stat` with the existing bounded file reader. This path
works without the Linux 3.17 thread-self symlink. IDs are never string-coerced
from unexpected objects, and the parsed task ID must match the path's ID.

An absent/invalid/unimplemented native-ID API or a failed task-file read/parse
falls back to `/proc/thread-self/stat`, at most once. Missing paths (ENOENT or
ENOTDIR) are normal absence; if neither facility works the section is omitted.
If an unexpected first-path error occurs and the fallback is absent, that error
is re-raised into the field's normal capture boundary rather than hidden. A
successful fallback suppresses the failed first attempt; a failing fallback
reports its own unexpected error. Fatal exceptions are never rescued.

The new `parse_stat` helper extracts TID and field-22 start ticks, handling spaces,
newlines and parentheses in comm. Both process and thread use `lifetime(ticks)`
to compute the same four lifetime fields as before. Invalid IDs, negative start
ticks, invalid clock rates and non-finite/negative uptime are rejected instead
of guessed. File reads and references remain request-local. The process-age
calculation and its output fields are retained for valid input.

`Snapshot#collect_current_thread` checks the known child selector paths before
any discovery. It captures TID and lifetime separately, so TID-only selection
skips Etc/uptime, and a failed lifetime calculation leaves the TID intact. The
normal output projection handles deeper selectors such as lifetime.age_seconds.
Only this new collector avoids thread enumeration; the existing independent
process.ruby_threads metric uses a guarded Thread.list count when selected.

The result describes the sampled native task, not a portable Ruby Thread birth
timestamp. M:N scheduling may change the native TID before/after observation;
no identity pinning or scheduler manipulation is attempted. Do not infer request
duration, thread-local request ordinal or total requests from thread age. No
Passenger/Puma-specific integration, startup/fork hook, stored timestamp,
thread-local entry, native binding, command or additional dependency is used.

There is no full smaps fallback when smaps_rollup is unavailable. `/proc/self/maps`
is scanned only for allocator-library names; it is not returned wholesale and
cannot identify statically linked allocators or prove active allocation routing.

## Thread and procfs inventory (0.7.0)

The new collectors are request-local. ThreadInfo.list accepts only a core
Thread singleton list method (no Ruby source location); instance readers are
obtained as UnboundMethods from Thread or BasicObject, with matching owner and
no Ruby source location. They bypass per-object/subclass overrides. Globally
replaced/prepended methods are skipped rather than searching ancestors or
restoring monkey patches. The same list guard now protects ruby_threads.
These are conservative availability checks, not proof against arbitrary native
monkey patches, instrumentation or VM bugs; some engines may return less data.

Snapshot collects summary fields and up to 256 basic entries, or 64 backtrace
entries when explicitly enabled. Each field has its own capture boundary with
an indexed error path. The JSON items array is still atomic for selectors.
Summary-only selection does not obtain/read instance methods. Core Thread.list
still allocates the entire visible-thread array; limits bound inspection/output,
not that runtime allocation. Thread objects stay rooted only during collection.
Names and frame text are copied into bounded 1024-byte prefixes and normalized
(invalid UTF-8 becomes a Base64 descriptor). Ordinary failures do not discard
neighboring threads; fatal exceptions propagate normally.

Backtraces call the core bounded API with offset zero and a 65-frame length.
Only 64 frames are returned, with flags for frame-count/text truncation. There
is no unbounded retry when an implementation rejects arguments. No locals,
exception objects, Backtrace::Location objects, source files or native memory
are inspected. Runtime capture may perform synchronization or more temporary
allocation than the returned prefix; no hard latency/allocation guarantee is
made. No gem-issued thread controls, asynchronous timeout, signal or lock is
introduced. Backtraces remain default-off, not part of routine inventory.

The existing stat parser now also retains raw fields 14/15 in its request-local
result. Conversion validates them separately in cpu_seconds, so corruption or
clock failure cannot suppress a valid TID/lifetime. The same native-ID lookup
and bounded stat read serve both age and CPU counters. CPU conversion does not
read uptime; TID-only selection invokes neither calculation. Values describe
the sampled native task; M:N and changing-thread caveats remain.

FD and namespace enumeration use fixed procfs directories, constrained entry
names, limits of 1024/64 and one lookahead. Directories close before per-link
reads. File.readlink reads link contents only; it never opens targets, acquires
descriptor ownership, reads file offsets, resolves socket peers or enters a
namespace. Individual failures during normal enumeration are captured, not
retried. Missing directories are optional absence. Links longer than 4096 bytes
are rejected. The 0.7.2 permission fallback is described below. Metadata-only
limit selection skips enumeration, and individual namespace/FD link selection
skips other readlinks. These caps do not create filesystem timeouts.

Snapshots are not atomic: thread state, IDs, FD reuse and namespace links may
change while read. Ractor scope and process-view/main-thread namespace scope
are documented. No collection arrays, Threads, methods, native handles or
baselines are retained after response serialization. Existing response/body,
authentication-before-collection, delay, secret omissions and presentation
order are unchanged. Structured cgroup reporting remains in TODO.md; the old
raw membership read remains. No snapshot deltas are introduced.

## Structured process limits (0.7.1)

`process.linux.limits` retains the existing read of `/proc/self/limits`, bounded
to 64 KiB, but passes its temporary text to `LinuxProcess.parse_limits`. The
result is a map from normalized resource names to soft/hard/units. There is no
raw-text output or fallback, no getrlimit call and no additional file access.

The parser processes each line separately using horizontal whitespace between
name/value/unit tokens. Kernel padding widths are minimums, so it does not rely
on two spaces or fixed column positions: a 20-digit finite value can leave only
one separator. Header layout is irrelevant because header rows do not match.
ASCII resource words and optional unit tokens are accepted without a fixed
resource list. Finite values use Integer(text, 10), unlimited stays a string,
and absent units become nil. Headers/malformed lines are skipped independently;
an empty result is valid best-effort output. No line joins across newlines.

The existing capture boundary checks selection before reading, normalizes the
parsed primitives and records ordinary file/parser failures under
process.linux.limits. Dotted selection projects the parsed fields afterward.
Fatal exceptions propagate. All input, match data and result objects are local
to the current request; nothing is cached or shared across requests.

## Namespace discovery permission fallback (0.7.2)

`namespace_names` first uses the existing `Dir.foreach`-based bounded discovery.
Only EACCES and EPERM select a frozen list of ten known names. This branch does
not read links itself: it returns candidates with an internal fallback marker,
so the snapshot can honor dotted selection before probing. The marker is never
serialized. ENOENT/ENOTDIR still omit the optional directory, and other ordinary
enumeration failures still produce the usual section error.

For selected fallback candidates, the snapshot uses the existing bounded
`link_target` helper. Ordinary failures, including missing names on old kernels,
denied links and oversized targets, omit that candidate without adding a null
entry or error. Fatal exceptions propagate. This behavior is confined to the
namespace fallback: normal namespace discovery and FD detail failures retain
their prior null/error behavior. No link is opened or followed, and no prctl,
permission change, namespace operation, lock or shared mutable state is added.

The public limit/truncated/entries shape is unchanged. Empty fallback entries
means no selected readable observations. A false truncated flag says only that
the candidate list was not cut off; the fixed fallback cannot discover unknown
future namespace names. Successful directory enumeration remains dynamic.
Limit-only requests skip discovery; truncated-only requests do no readlinks.
All lists/results are request-local or immutable constants, with no cached
success/failure across requests.

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

Thread-lifetime references checked for 0.4.0 (documentation review, not an
old-kernel execution test):

- Ruby 3.4 native thread IDs and M:N caveat: https://docs.ruby-lang.org/en/3.4/Thread.html#method-i-native_thread_id
- Linux task directories (2.6.0+) and thread-self (3.17+): https://man7.org/linux/man-pages/man5/proc_pid_task.5.html
- Linux stat field 22 and clock-tick units: https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html

Authentication references checked for 0.5.0 (documentation/source review):

- Basic credentials, colon delimiter, control characters and TLS requirement: https://www.rfc-editor.org/rfc/rfc7617.html
- nginx password-file syntax and supported SSHA/PLAIN schemes: https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html
- nginx SSHA digest/salt format: https://github.com/nginx/nginx/blob/master/src/core/ngx_crypt.c
- dotenv-rails before_configuration loading: https://github.com/bkeepers/dotenv#customizing-rails

These references establish format/interoperability context; this implementation
intentionally rejects duplicate users, empty passwords, unsupported schemes and
malformed whole files instead of emulating every permissive nginx behavior.

Delay references checked for 0.6.0 (documentation/source review):

- Ruby 2.4 Kernel.sleep: https://docs.ruby-lang.org/en/2.4.0/Kernel.html#method-i-sleep
- Ruby 3.4 Kernel.sleep and fiber-scheduler delegation: https://docs.ruby-lang.org/en/3.4/Kernel.html#method-i-sleep

These document fractional seconds, thread wakeup and scheduler behavior, not
production Passenger/Puma routing, resource limits or request-timeout handling.

Inventory/CPU/procfs references checked for 0.7.0 (documentation/source review):

- Ruby 2.4 Thread core readers and backtrace entry point: https://docs.ruby-lang.org/en/2.4.0/Thread.html
- Ruby 3.4 Thread status, native IDs, list and backtrace: https://docs.ruby-lang.org/en/3.4/Thread.html
- Linux stat fields 14/15 and clock-tick units: https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html
- Linux FD symlink semantics: https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html
- Linux namespace links and per-thread distinctions: https://man7.org/linux/man-pages/man7/namespaces.7.html

These describe APIs, not a guarantee against runtime bugs or a replacement for
live deployment testing. No upstream source code has been vendored.
