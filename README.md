# rails_runtime_info

A small, on-demand diagnostic Rack endpoint for Rails applications. Add the gem
and one route; inspect a pretty-printed JSON snapshot when troubleshooting.

**This endpoint deliberately returns credentials present in HTTP requests and,
when selected, the process environment. Authentication is off by default.
Rails-injected request-environment entries are narrowly whitelisted to avoid
exposing server signing/encryption secrets; this is not general-purpose secret
redaction. Protect the route with the opt-in Basic-auth wrapper below or a trusted
ingress, over TLS and with appropriate network restrictions.**

## Motivation and constraints

The intended use is occasional, internal troubleshooting across several Rails
applications: which Ruby, gems, deployment and worker are actually running;
what the proxy sent; how GC, YJIT and process memory look at that moment.

This is a non-invasive, best-effort, **read-only observer**, not a health check,
profiler, management interface, dependency checker or application controller.
The gem must not initialize services or change how ordinary application
requests execute. It must remain useful when an optional collector fails.

Requiring it defines the implementation only. There is no Railtie, engine,
global middleware, initializer, Passenger hook, background thread, instrumentation,
monkey patch or automatic route registration. There are no declared runtime gem
dependencies; JSON and small standard-library facilities are loaded only when
needed for a diagnostic request. Existing Rails/Rack/Bundler installations are
observed, not required or reconfigured.

## Install and route

Restore the repository from the supplied full Git bundle:

```sh
git clone rails_runtime_info-0.7.1-full.bundle rails_runtime_info
```

For an adjacent local checkout, add this to the application's Gemfile in a group
that is loaded in the environments where the endpoint is needed:

```ruby
gem "rails_runtime_info", path: "../rails_runtime_info"
```

For shared deployments, push the restored repository to your private Git host
and use the organization's normal pinned Git-gem dependency convention. There
is no assumed public RubyGems release. Alternatively, build the gem in this
repository and distribute it through your private gem repository:

```sh
gem build rails_runtime_info.gemspec
```

Load the gem explicitly before referencing its endpoint, then add the route
**inside the application's existing routes block**, before any catch-all or
controller-authentication constraint. In `config/routes.rb`:

```ruby
require "rails_runtime_info"

Rails.application.routes.draw do
  match "/_internal/diagnostics", to: RailsRuntimeInfo::Endpoint, via: :all, format: false
  # Existing routes follow.
end
```

Use the existing routes block rather than creating a second one just for this
gem. A normal `Bundler.require` for the gem's group usually loads it already;
the explicit `require` is harmless in that case. It is needed when, for example,
the Gemfile sets `require: false`, the application only uses `bundler/setup`, or
the relevant group is not automatically required. The gem must still be installed
and available in the active bundle. No Railtie or autoload configuration is needed.

`format: false` avoids the usual optional format suffix. Check that ingress
protection and Rails route matching cover the same paths, including any path
normalization, trailing slash or mount prefix accepted by the deployment.
Protecting the entire internal diagnostic namespace is safer than an exact
proxy match whose semantics differ from the router's.

The endpoint class does not choose a path; the route does. `via: :all` permits
request inspection with different HTTP methods. HEAD returns response headers
but no response body. There is no application-controller authentication, CSRF
handling or Rails/Rack request-parameter parsing in this gem. Existing application
middleware and outer route constraints still apply and can reject or modify a
request first.
The gem interprets only its own `what` and `sleep` query parameters; it does not invoke Rails/Rack
parameter parsing or parse the request body.

Normal Bundler installation and application restart/deployment procedures still
apply. Removing the route and Gemfile entry removes the integration.

## Optional per-route Basic authentication (0.5.0)

The original `RailsRuntimeInfo::Endpoint` remains unauthenticated. To protect
just the diagnostic route, replace its target with an explicit wrapper:

```ruby
match "/_internal/diagnostics", to: RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: "/etc/myapp/diagnostics.htpasswd"), via: :all, format: false
```

The factory returns a Rack-compatible callable. It does not add application-wide
middleware, alter another route, touch WebSocket handling, or require a Rails
initializer. It is implemented within this gem rather than instantiating
`Rack::Auth::Basic`; strict bounded decoding, immutable configuration and generic
fail-closed responses work without introducing a Rack or authentication-gem
dependency. The public factory accepts `htpasswd:` and optional `realm:` (default
`"Rails Runtime Info"`). Plain String paths are supported; convert a Pathname
explicitly before passing it. An absolute path is recommended.

### Path from ENV / dotenv-rails

For example, put this path (not the file's contents) in the application's `.env`:

```dotenv
RAILS_RUNTIME_INFO_HTPASSWD=/etc/myapp/diagnostics.htpasswd
```

In the **existing** `config/routes.rb` block:

```ruby
require "rails_runtime_info"

Rails.application.routes.draw do
  match "/_internal/diagnostics", to: RailsRuntimeInfo::Endpoint.basic_auth(htpasswd: ENV["RAILS_RUNTIME_INFO_HTPASSWD"]), via: :all, format: false
  # Existing routes follow.
end
```

**Use `ENV["RAILS_RUNTIME_INFO_HTPASSWD"]`, not `ENV.fetch(...)`.** The gem
cannot rescue an exception raised by a caller while evaluating its arguments.
An unset, empty or invalid path is accepted by the factory and creates a closed
endpoint returning **503**, not an unprotected endpoint. No password file is
opened and no digest library is loaded when the route is constructed. A missing
or unreadable file therefore does not prevent application initialization.

Normal `dotenv-rails` startup loads `.env` before routes. There is no dotenv
integration or dependency in this gem. The path is captured when the route is
defined: changing the environment variable needs route reload or application
restart. Creating or updating the file at that path takes effect on the next
well-formed authentication attempt, with no reload. Do not also leave an
unprotected alias of the endpoint accessible.

### Password-file format

One user per line, with **only** explicit `{SSHA}` or `{PLAIN}` schemes:

```text
# Illustrative test credentials only; do not deploy these values.
alice:{SSHA}7f5oxwoLw9l/oUGGRBiKWy6vhH0Ac2FsdP8=
bob:{PLAIN}second-pass:optional comment
```

The illustrative SSHA entry verifies `sample-pass`. It contains Base64 of the
20-byte SHA-1 digest of password bytes followed by salt bytes, then the salt
itself: `Base64(SHA1(password + salt) + salt)`. At least one salt byte is required.
The full Base64 value is decoded strictly; malformed/truncated values and an
unsalted 20-byte digest are rejected. No bcrypt, apr1, crypt, SHA or unprefixed
plaintext fallback is implemented.

Multiple users, LF/CRLF, a final line without a newline, blank lines, `#` comments
(with optional preceding spaces/tabs) and a third colon-delimited comment field
are supported. Names and passwords are byte-exact and case-sensitive; spaces in
credentials are not stripped. Empty usernames/passwords and control characters
in decoded credentials or PLAIN fields are rejected. The third colon-delimited
field starts a comment, so a literal colon cannot be stored in a PLAIN password;
use SSHA for a password containing colons. Non-ASCII bytes must match the file's
encoding; the gem does not normalize or guess character encodings.

**A malformed line, duplicate username or unsupported scheme anywhere in the
file invalidates the entire file.** It is not skipped and a valid earlier entry
cannot authorize access. This conservative policy deliberately differs from
permissive readers that stop at the first matching username. An empty or
comment-only file also keeps the endpoint closed.

Use a small local regular file, readable by the worker and writable only by its
administrator. The file is reread for every syntactically valid credential
attempt; no plaintext, hashes, parsed user list or authentication result is
cached. Replace it atomically to avoid exposing an in-place partial edit to
concurrent requests. Symlinks are permitted, but the opened target must be a
regular file. File size is limited to **64 KiB** (read at most one extra byte);
an oversized file is rejected, never authenticated from a truncated prefix.
The Authorization header is limited to **16 KiB**. Paths are limited to 4096
bytes and realms to 256 printable ASCII bytes; quoted realm characters are
escaped. Invalid configuration remains closed instead of raising on route setup.

### Responses, confidentiality and scope

| Condition | Result |
| --- | --- |
| Valid credentials | Original endpoint runs, with its existing selection, status, headers and body behavior. |
| Missing/malformed credentials, unknown user or wrong password | **401**, JSON `{"error":"unauthorized"}` and `WWW-Authenticate: Basic realm="Rails Runtime Info"` (or the configured realm). |
| Missing/invalid path or realm, missing/unreadable/oversized/nonregular/invalid file, ordinary verification failure | **503**, generic JSON `{"error":"authentication_unavailable"}`; no exception details, filesystem paths or file contents. |

A configured path with missing/malformed credentials returns 401 without opening
the file; file problems become 503 on a well-formed credential attempt. Invalid
route configuration itself returns 503 immediately. Both rejections use
`Cache-Control: no-store`, lowercase Rack headers and an empty body for HEAD.
All HTTP methods are authenticated. Rejected requests do not run collectors,
parse `what` or `sleep`, wait, or read `rack.input`. Fatal exceptions are not swallowed.

Only `HTTP_AUTHORIZATION` is used; proxy headers, `REMOTE_USER` and query/body
values cannot authorize access. Successful authentication neither rewrites the
Rack environment nor sets `REMOTE_USER`. **The original Authorization header
remains in selected request output, as requested**; Basic credentials can be
recovered from it. Protect saved/shared diagnostic output accordingly. Password
file contents and verifier errors are never deliberately added to diagnostics.

Digest comparisons inspect every byte of fixed-size digests (SHA-1 for SSHA;
SHA-256 of both inputs for PLAIN). This avoids ordinary String prefix/length
comparison of passwords; it is not a guarantee that Ruby execution, username
lookup or the whole request has constant timing. No login cache, sessions,
lockouts or rate limiting are added. Use network/server controls for abuse.

Basic authentication does not encrypt credentials: use TLS on the client-facing
connection. PLAIN stores a recoverable password, and single-round SSHA is cheap
to guess offline; these are the explicitly requested compatibility formats,
not a password-storage recommendation. Avoid reused credentials. The wrapper
retains only immutable route configuration and the endpoint class. Parsed file
contents and decoded credentials become eligible for ordinary GC after checking;
there is no forced GC or guaranteed secure memory wiping.

## Optional request delay (0.6.0)

Add `sleep=N` to deliberately keep a diagnostic request in progress, helping
occupy request-handling slots while sending other diagnostic requests:

```text
/_internal/diagnostics?sleep=15
/_internal/diagnostics?what=-all,process,server,runtime&sleep=0.5
```

No route change or initializer is needed. It works with both the bare endpoint
and the optional Basic-auth wrapper. The order is **authenticate (when enabled),
validate `what` and `sleep`, sleep, collect diagnostics, serialize, respond**.
Both parameters are fully validated before waiting, regardless of their query
order. Invalid `what` still returns `invalid_what`; invalid `sleep` returns
HTTP **400** with `error: "invalid_sleep"`. Authentication rejections still
return 401/503 before any query validation, sleep or collection.

The parameter is query-string-only, not a request-body field or header. Its
case-sensitive, form-decoded name is exactly `sleep`. Repeated parameters,
including percent-encoded spellings of that name, are rejected rather than
summed or resolved by first/last value.

| Value | Behavior |
| --- | --- |
| Absent, `0` or `0.0` | No sleep call. Ordinary requests have no deliberate delay. |
| `0.5`, `5`, `15`, `30` | One `Kernel.sleep` call before snapshot construction. |
| Empty, negative, signed, malformed, non-finite or above 30 | 400 without sleeping, collecting diagnostics or reading `rack.input`. |

Values must be unsigned ASCII decimal integers or fractions with digits on both
sides of the decimal point; leading zeros are accepted. For example `.5`, `1.`,
`+1`, surrounding whitespace, `1e1`, `NaN` and `Infinity` are rejected. The limit
is **30 seconds inclusive** and the decoded value is limited to **64 bytes**.
The exact decimal bound is checked before floating-point conversion, so a value
fractionally above 30 cannot slip through rounding. Unrelated query values are
not decoded. Existing `what` defaults and selection semantics are unchanged.

No snapshot or JSON response is allocated until after sleeping. The existing
request environment and small validated selection remain live while the request
is waiting; there is no persistent delay state, timer, extra thread or lock.
Diagnostics, including timestamps and counters, describe the state **after** the
wait. No `request.sleep_seconds` or other dedicated delay field is added. The
original query string remains visible wherever existing request output includes
it. HEAD and other permitted methods obey the same delay; HEAD still has no body.

**This deliberately consumes serving capacity; it is not a process-routing
API.** With an ordinary thread-per-request server, one sleeping request occupies
one request thread, not every thread in that PID. Other threads in a Puma worker
can still serve requests. A single-threaded Passenger worker can be kept busy,
but another worker must exist or be spawnable; otherwise additional requests can
queue. A Ruby fiber scheduler may handle sleep cooperatively instead of tying up
an entire native thread. No scheduler, server routing or worker settings are
changed, and a different PID is not guaranteed.

Keep the endpoint protected and keep delays below your client/proxy/server
request timeouts. Thirty seconds is a per-request requested-delay cap, not a
concurrency limit or a hard bound on total response time. Many overlapping
requests can exhaust serving capacity. Scheduling or explicit thread wakeups can
change actual elapsed time. Disconnecting the client is **not** a cancellation
mechanism: the application may continue sleeping/collecting until the server
notices. No disconnect watcher, busy loop, timeout override or retrying sleep is
introduced.

## Compatibility

The code targets **Ruby 2.4+ and Rails 5.1+**, without requiring Rails to use the
Rack callable. Optional methods and constants are checked before use. Linux
collectors are optional; a non-Linux application still gets the other sections.
There is no Passenger or Puma dependency. The response uses lowercase headers and does
not require a rewindable Rack input stream, accommodating Rack 2/3 conventions.

These are implementation targets, not a claim that every version combination
has been tested. See [validation](docs/VALIDATION.md) for exactly what was run.
The application itself must support its chosen Ruby/Rails/Rack combination.

## New in 0.7.1

`process.linux.limits` is now a structured object instead of a raw text string.
Resource names are snake_case keys with `soft`, `hard` and `units` fields.
The raw file contents are no longer returned. Any consumer expecting a string
must adapt; no route changes or new dependencies are required.

## Added in 0.7.0

Basic thread inventory, current-native-thread CPU counters and Linux namespace
IDs are included by default. Thread backtraces and detailed FD links are opt-in.
No route changes or new dependencies are required. Cgroup resource reporting
is deferred in [TODO.md](TODO.md); raw cgroup membership is unchanged. Snapshot
deltas are not implemented.

## Collected information

| Section | Contents |
| --- | --- |
| `runtime` | Ruby description/version/engine/platform/executable, selected build information and versions of relevant activated libraries. |
| `application` | Already-instantiated Rails application identity, environment, root, initialization state, selected configuration, existing cache backend class and configured job-adapter value. Selected deployment environment variables are highlighted. |
| `gems.activated` | All entries from `Gem.loaded_specs`, with name, version and platform; excluded by default. Activated does not mean every library file has been required. |
| `environment` | Full `ENV`, with no filtering; excluded by default. |
| `loaded_features`, `load_path` | Copies of `$LOADED_FEATURES` and `$LOAD_PATH`; excluded by default. |
| `gc` | Complete results of available `GC.stat`, `GC.latest_gc_info` and `GC.stat_heap` calls. |
| `yjit` | Availability, enabled/statistics flags where supported and the complete available `runtime_stats` result, including `null` when returned by Ruby. |
| `process` | PID/PPID, user/group IDs, Ruby thread count, bounded thread inventory, opt-in backtraces, CPU time, working directory, program name, arguments and `Etc.uname`. No account-name or hostname lookup is performed. |
| `process.linux` | `/proc/self/status`, `smaps_rollup`, I/O counters, structured resource limits, raw cgroup membership, command line, executable link, FD count and opt-in link details, namespace link IDs, estimated process/current native-thread lifetimes and current-thread CPU time, OS release and allocator-library hints. |
| `server` | Rack's server-software value, existing Passenger version information, and optional `passenger.thread_iteration` / `puma.requests_count` readings from the current handler/server. A loaded version constant alone does not prove which server handled the request. |
| `request` | Method, URI fields, query string, scheme/protocol/address metadata, all available HTTP header values, reconstructed URL, safe Rack-environment snapshot and opt-in bounded raw body. |
| `errors` | Independently failed collectors, with exception class and best-effort message. |

No database collector is present, not even connection-pool inspection. There
are no SQL queries, database connections, Redis calls, job-adapter initialization,
network calls, external commands or application-health checks. There are no
custom collector callbacks in this version.

### Process resource limits (0.7.1)

`process.linux.limits` parses `/proc/self/limits` into an object such as this
illustrative fragment:

```json
{
  "max_open_files": { "soft": 1024, "hard": 1048576, "units": "files" },
  "max_address_space": { "soft": "unlimited", "hard": "unlimited", "units": "bytes" },
  "max_nice_priority": { "soft": 0, "hard": 0, "units": null }
}
```

Finite values are parsed as base-10 Ruby Integers and emitted as JSON integers;
they are not converted through floating point. `"unlimited"` stays a string,
and missing units become `null`. Resource names are normalized to snake_case.
No fixed list of resources or column widths is assumed. Headers and malformed
rows are skipped; an empty or wholly unrecognized file produces `{}`. A failed
read or parser produces `null` and `errors["process.linux.limits"]` as usual.

This remains one bounded file read, at most **64 KiB**, with no `getrlimit`
calls, hooks or retained state. Oversize files are rejected rather than parsed
as a partial success. The raw contents are neither returned nor cached. Cgroup
membership remains a separate raw-text field.

```text
?what=-all,process.linux.limits.max_open_files,errors
```

Dotted selection filters the parsed values. Excluding the entire limits field
skips both reading and parsing.

### Process and current native-thread age

Process age is already available at `process.linux.lifetime`. Version 0.4.0 adds
`process.linux.current_thread`, included by default when obtainable on Linux.
For example (illustrative values, not a live snapshot):

```json
{
  "process": {
    "linux": {
      "current_thread": {
        "tid": 12346,
        "lifetime": {
          "start_ticks_since_boot": 25000,
          "clock_ticks_per_second": 100,
          "age_seconds": 3600.5,
          "started_at_utc_approximate": "2026-11-16T17:00:00.000000Z"
        }
      }
    }
  }
}
```

Discovery is passive and attempted in this order:

1. When `Thread.current.native_thread_id` is available and returns a positive
   Integer, read `/proc/self/task/<TID>/stat`. This is the old-kernel path:
   `/proc/<pid>/task` exists since Linux 2.6.0 and does not need `/proc/thread-self`.
   The TID parsed from the file must match the requested TID.
2. Otherwise, or after an ordinary failure of that lookup/read/parse, try
   `/proc/thread-self/stat`. This works without the Ruby native-ID method on
   kernels providing that path (Linux 3.17+). Each path is tried at most once.

The native-ID method is available in Ruby 3.4; the collector does not require
it for loading or for the modern-kernel fallback. This is intended to cover
CentOS 6 / Linux 2.6.32 workers running a Ruby with native-TID support. **That
specific old-kernel/Ruby 3.4 combination has not been executed in validation.**
On an older Ruby without that API and an older kernel without thread-self, the
thread section is omitted; no native extension, Fiddle binding, raw syscall,
external command or scan of other tasks is attempted. Ruby 2.4 remains the
minimum implementation target.

The existing process-lifetime calculation is reused: field 22 supplies start
ticks, `Etc.sysconf(Etc::SC_CLK_TCK)` supplies the conversion rate, and
`/proc/uptime` supplies the current boot-relative time. The UTC timestamp is
only an estimate derived from the wall clock at collection. Collection is not
atomic with other metrics and does not retain baselines across requests/forks.

This is **native OS thread age, not request duration or necessarily Ruby Thread
object age**. With an M:N Ruby implementation a Ruby thread's native TID can
change; the result describes the native task sampled, without pinning threads
or promising that it still executes the request when the response is sent.

Missing paths/unsupported native-ID facilities omit the section. An unexpected
unrecovered lookup/read/parse failure produces `current_thread: null` and an
`errors["process.linux.current_thread"]` entry. A failed lifetime calculation
preserves the TID and reports `errors["process.linux.current_thread.lifetime"]`.
Recovered first-path failures do not create an error entry. Fatal exceptions
are not swallowed. Unrelated process/server information remains available.

The existing `what` syntax applies, for example:

```text
?what=-all,process.linux.lifetime,process.linux.current_thread,errors
```

To keep defaults except thread discovery:

```text
?what=-process.linux.current_thread
```

For only the current native TID, without reading uptime or obtaining clock ticks:

```text
?what=-all,process.linux.current_thread.tid,errors
```

Excluding `process.linux.current_thread` skips native-ID discovery and both task
stat reads. Excluding its `lifetime` skips the thread's age calculation (the
independently selected process lifetime may still read uptime). The current-thread collector does not enumerate other threads. No hooks,
server-specific calls, new threads, locks, caches or persistent references to
Thread objects are added. Source references are in [design notes](docs/DESIGN.md).

### Thread inventory and opt-in backtraces (0.7.0)

`process.threads` contains `total`, `limit`, `truncated`, and `items`. Each item
has the available `object_id`, `native_tid`, `status` and `name`. At most **256**
threads are inspected. Names are limited to **1024 bytes**, with
`name_truncated: true` when shortened. An unnamed thread has a null name; a
thread that has exited can have false/null status or a null native TID.
Unsupported readers are omitted, rather than fabricated.

```text
?what=-all,process.threads,errors
```

`process.thread_backtraces` is **excluded by default**. It has the same summary
fields but examines at most **64** threads. Each item has an `object_id` for
correlation and a `backtrace` object containing `frames`, `frames_truncated`,
and `frame_text_truncated`. Backtraces have at most **64 frames per thread**,
and each frame string is limited to **1024 bytes**. A terminated thread can
have a null backtrace. Truncation is explicit; it is not a complete thread dump.

```text
?what=-all,process.threads,process.thread_backtraces,errors
```

The collector calls the bounded core `Thread#backtrace(0, 65)` API, using the
extra frame to detect truncation. It never retries an unsupported bounded API
with an unbounded call. This bounds returned data, **not necessarily all work
or temporary allocation within the Ruby VM**. Backtrace capture is more work
than inventory and may briefly coordinate with other threads inside the VM.
Use it for occasional troubleshooting, not polling; there is no hard timeout or
absolute guarantee against Ruby/native-extension bugs. It never calls join,
value, wakeup, kill, thread-local readers, or thread-control methods.

For new inventory/backtrace readers, unbound core methods bypass singleton and
subclass overrides. Ruby-defined or prepended replacements are skipped, not
called. The thread count now uses the same guarded core `Thread.list`; if it
is replaced/unavailable, `ruby_threads` is null and the new inventories are
omitted. Some non-CRuby implementations may consequently provide less data.
There is no attempt to recover replaced methods or alter the running program.
Per-field failures appear in `errors` with paths such as
`process.threads.items.0.name`; other fields and threads remain available.
Fatal exceptions still propagate.

`Thread.list` allocates an array of all visible Ruby threads even when the
reported inventory is capped. On CRuby with Ractors this is the **current
Ractor's threads**, not every Ruby thread or native task in the process. No
ObjectSpace, task-directory traversal or native thread identification fallback
is used for the inventory. IDs and statuses can change between reads; native
TIDs can migrate under M:N threading, and object IDs are not persistent worker
identifiers. `ruby_threads`, inventory and backtraces are separate samples and
may disagree. Only copied primitive metadata reaches the response; no Thread,
UnboundMethod, stack location or enumeration array is retained in it.

The existing array-selection rule applies: `.items` selects the whole array,
not individual indexes or fields within its rows. Selecting only `.total`
does not inspect per-thread fields or collect backtraces. Excluding the whole
thread section skips its enumeration.

### Current native-thread CPU time (0.7.0)

`process.linux.current_thread.cpu_seconds.user` and `.system` are cumulative
seconds for the native task whose `tid` was sampled. They are **not CPU
percentages, request CPU time, or the sum across all application threads**.
They reuse fields 14 and 15 of the existing bounded task-stat read, divided by
`Etc.sysconf(Etc::SC_CLK_TCK)`. No extra stat-file read or sampling interval is
introduced. The existing native-ID/task path and thread-self fallback remain.

```text
?what=-all,process.linux.current_thread,errors
```

CPU and lifetime calculation fail independently. Bad CPU values leave a valid
TID/lifetime intact. Selecting `.cpu_seconds` alone skips the age/uptime
calculation; selecting only `.tid` still skips both age and CPU conversion.
Under M:N scheduling the values belong to the sampled OS thread, not
necessarily the complete execution history of a Ruby Thread object.

### FD details and namespace IDs (0.7.0)

`process.linux.fd_details` is **excluded by default**. It contains `limit`,
`truncated`, and `entries`, a map of descriptor-number strings to symlink
contents such as `socket:[12345]`, `pipe:[67890]` or `/var/log/app.log`.
Enumeration stops after **1024 entries plus one lookahead**; the response
reports truncation and does not claim an exact total. The existing `open_fds`
count is unchanged and may sample a different instant.

```text
?what=-all,process.linux.fd_details,errors
```

Only `/proc/self/fd` directory entries and `readlink` are used. Descriptors are
never duplicated, opened, read, closed or otherwise operated on. A descriptor
can close or be reused before its link is read; failed entries become null with
individual error paths. The enumeration directory's own temporary FD can
appear and subsequently disappear; an ENOENT error for that entry is normal.
No socket-address lookup or fdinfo collector is included.

`process.linux.namespaces` is **included by default** when available. It has
`limit`, `truncated`, and `entries` mapping names (for example `net`, `mnt`,
`pid`) to `/proc/self/ns/*` link targets. Enumeration is capped at **64** entries
plus one lookahead; names are discovered rather than assuming a modern kernel.
A missing directory is omitted, and a failed individual link is isolated.
These are the process-view/main-thread namespace links, not a promise that
all worker threads share those namespaces. Compare IDs only within the same
host/kernel context; they are not globally unique identifiers. Child-namespace
entries, when present, retain their actual kernel names and semantics.

```text
?what=-all,process.linux.namespaces,errors
```

A namespace-specific selector such as
`process.linux.namespaces.entries.net` reads only that link after enumeration.
Symlink results are bounded to **4096 bytes**; larger results are reported as
errors. Symlink targets are never followed. Missing procfs on old kernels or
unsupported platforms must not prevent unrelated collectors from working.
The new inventory data is not cached, and no target objects/handles survive
into the response body.

**Parent rules still reset child exclusions.** `what=all` or `what=process`
explicitly enables backtraces and FD details, even though default requests omit
them. To include all other process information without either expensive list:

```text
?what=-all,process,-process.thread_backtraces,-process.linux.fd_details,errors
```

### Passive server counters

Version 0.3.0 adds two optional fields under the existing `server` category:

| Field | Source and meaning |
| --- | --- |
| `server.passenger.thread_iteration` | Reads `Thread.current[:passenger_thread_handler].iteration` when the handler and reader exist. This is the current Passenger Ruby handler's iteration, including the current request. It is **per handler thread**, not Passenger core's process-wide `Processed` count. PING, out-of-band work and malformed connections can also advance it. |
| `server.puma.requests_count` | Reads `Puma::Server.current.requests_count` when the constants and methods are already available. This is the current worker/server's existing count, advanced before Rack application dispatch. Concurrent requests share it, so it is **not a unique request sequence number** or a completed-request count. It is not summed across Puma workers. |

Both are included by the default selection when available. For just server
information and collection errors:

```text
?what=-all,server,errors
```

The fields also work with the existing dotted selectors:

```text
?what=-all,server.passenger.thread_iteration,server.puma.requests_count,errors
```

To retain default diagnostics but skip both counter reads:

```text
?what=-server.passenger.thread_iteration,-server.puma.requests_count
```

An unavailable API, missing handler/server, or value other than a nonnegative
Integer omits the corresponding counter object; it is not guessed or converted
to zero. An exception follows the normal collector convention: the field is
`null` and its full path appears in `errors` when selected. The other counter
and unrelated diagnostics remain available. Existing `passenger_version` and
`passenger_constant_loaded` fields are unchanged.

There is no `require` or autoload of either server, counter installation,
mutation, mutex acquisition, cross-thread scan, status command, control-socket
query, hook or persistent object retention. In particular, the gem does **not**
call `Puma.stats`, `Puma.stats_hash` or `Puma::Server#stats`, whose implementations
can reset other statistics. Counter reads are skipped when deselected.

Passenger's internal lookup uses Ruby's fiber-local `Thread#[]` storage. Moving
execution to a different fiber/thread may make that handler unavailable; the
gem does not hunt for a replacement. These are best-effort internal API reads,
not guaranteed across all server versions or Passenger Enterprise variants.
Neither counter is promised atomic with the rest of the diagnostic snapshot.
See [design notes](docs/DESIGN.md) for source references and
[validation](docs/VALIDATION.md) for the untested live-server combinations.

### Selecting sections with `what`

The initial selection is always:

```text
all,-loaded_features,-load_path,-gems,-environment,-request.body,-process.thread_backtraces,-process.linux.fd_details
```

The optional `what` query parameter is a comma-separated sequence applied
**after those defaults, from left to right**. A bare name includes that section;
a leading `-` excludes it. An explicit `+` remains accepted for compatibility but
is unnecessary. `all` enables everything available, including the request body, backtraces and FD details;
`-all` disables everything, including `gem_version`, `time_utc` and `errors`.
`all` is special only as the whole name.
A later rule for a parent replaces earlier rules for that parent and its
children. Selecting a child of a disabled parent brings back only that child,
not its siblings.

| Decoded `what` value | Effect |
| --- | --- |
| `all` | All available categories, still subject to permanent secret omissions and body/normalization limits. |
| `gems,environment` | Defaults plus activated gems and full ENV. |
| `-all,request` | Request information only, including the bounded body. |
| `-request.rack_environment` | Defaults, without the request's Rack-environment snapshot; the body remains excluded. |
| `-all,request.headers,request.metadata` | Only request headers and metadata. Does not read the body. |
| `request.body` | Defaults plus bounded body capture. |
| `request,-request.body` | Restore the request section, then exclude its body; `rack.input` is not read. |
| `-all,gc.stat.count,errors` | Only the GC count and collection errors. The GC API still returns its whole hash internally. |
| `-all,request.rack_environment.action_dispatch.request_id` | Only an already-present Rails request ID. |
| `-request.rack_environment,request` | The later parent inclusion restores the entire permitted request section, including body capture. |

Names are case-sensitive and match top-level JSON keys. Current names are:
`gem_version`, `time_utc`, `process`, `server`, `gems`, `environment`,
`loaded_features`, `load_path`, `errors`, `gc`, `yjit`, `runtime`, `application`,
`request`. Top-level output follows this order, with selected members of
**`gc`, `yjit`, `runtime`, `application`, `request` last**. GC/YJIT collection
still happens early; display order does not change the sampling order.

Dotted paths select JSON-object descendants. Dots inside flat Rack keys also
participate in these paths, but the returned Rack keys remain flat. There is
no escaping syntax for distinguishing a literal dot from a path separator.
Arrays are atomic: selecting `gems.activated` returns the array; selectors do
not address array indexes or project properties of its elements. Missing nested
keys are harmless no-ops because optional collectors and statistics vary.

Excluded top-level collectors and separately collected fields are skipped,
not merely hidden. In particular, excluding `request.body` avoids reading input,
and excluding `request.rack_environment` avoids normalizing that environment.
A narrower leaf selector may still require its parent API call, such as
`GC.stat`; it does not promise zero work on every unreturned sibling.
Selection itself does not provide access control.

Bare inclusion names need no plus-sign encoding. For request headers and
metadata only, use a plain URL:

```sh
curl --user diagnostics 'https://app.internal/_internal/diagnostics?what=-all,request.headers,request.metadata'
```

That example prompts for the Basic-auth password and leaves `rack.input` unread.
To add body capture to the defaults, use:

```text
/_internal/diagnostics?what=request.body
```

Query parsing still uses standard form decoding. Legacy `%2Brequest` selectors
remain valid; a literal `+request` also works because `+` decodes to surrounding
whitespace and bare `request` now means inclusion. Prefer bare names.

Repeated `what` parameters are concatenated in query order. An absent or empty
value changes nothing. Surrounding spaces around individual tokens are allowed.
Malformed tokens, unknown top-level names, invalid percent
encoding, non-printable/non-ASCII selectors, or limit violations return a JSON
**400** with `error: "invalid_what"` before diagnostics/body collection. Limits
are 8 KiB of combined decoded selector text, 128 user rules and 24 path
components. Empty tokens between commas are invalid. Other query parameters
are not interpreted, and their values remain available as request data.

### Activated gems only

`Gem.loaded_specs` is read without enumerating installed gem directories or
requiring the listed gems. There is no locked/resolved inventory and no
`Gemfile.lock`/`gems.locked` reader. `Bundler.load`, `Bundler.definition` and
Gemfile/gemspec evaluation are never used by the endpoint. Enable the list with
`what=gems` or `what=all`.

### Server-secret omissions in the Rack environment

These are the **only** `action_dispatch.*` entries returned, when present:

```text
action_dispatch.request_id
action_dispatch.remote_ip
action_dispatch.original_path
action_dispatch.request.path_parameters
action_dispatch.show_exceptions
action_dispatch.show_detailed_exceptions
```

Every other entry in that namespace is omitted altogether, not replaced by a
value-containing descriptor. In particular this removes `secret_key_base`,
legacy `secret_token`, `key_generator`, `cookies_rotations`, and any future
unrecognized Rails keys. Cookie salts are not themselves generally secret
keys, but are not on this small diagnostic whitelist either. Complex allowed
values, such as an already-created remote-IP object, remain opaque; the gem
does not invoke Rails accessors to materialize them.

`rack.session.options` is also omitted: Rack cookie middleware can place
current/previous signing secrets there. Nested `action_dispatch` containers
are omitted rather than interpreted as another configuration format. These
rules apply recursively within the Rack-environment snapshot, including
symbol-keyed entries and aliases. They never delete or mutate the actual env.
`all` and explicit dotted selectors cannot override them.

HTTP headers, raw query strings and the bounded raw body remain deliberately
unfiltered. Explicitly selecting `environment` still returns full process ENV:
**a secret supplied through ENV, including `SECRET_KEY_BASE`, can therefore
appear there**. Custom middleware can also put secrets under other names.
This namespace policy is not a universal secret detector or a guarantee that
the complete diagnostic response contains no credentials. Keep ingress
protection in place. See [design notes](docs/DESIGN.md) for upstream source
references supporting these omissions.

### Request fidelity and limits

HTTP header values, including Authorization, Cookie and custom credentials, are
not filtered. Header names in `request.headers` are reconstructed from Rack's
normalized names; original Rack keys remain in `request.rack_environment`.
Duplicate-header boundaries, original capitalization/order and exact wire bytes
already discarded by the server cannot be recovered. Forwarded headers are
reported as data, not trusted as authorization or independently interpreted.
`reconstructed_url` uses the Rack scheme, Host/server fields, script/path and
query; raw URI fields are reported separately when supplied by the server.

**Body capture is disabled by default.** Without an inclusion such as
`what=request.body`, `what=request` or `what=all`, the body collector is not
called and this gem leaves `rack.input` unread. Earlier middleware may already
have read or buffered it. Parent inclusions reset earlier child exclusions;
append `-request.body` after `request` or `all` to keep capture disabled.

When body capture is selected and an already-buffered Rails `RAW_POST_DATA`
String exists, its bounded prefix is used without copying the entire cache or
touching `rack.input`. Known raw and
parsed Rack body-cache entries in the Rack-environment snapshot are descriptors,
not duplicate payloads, so they cannot bypass this capture limit. These include
`RAW_POST_DATA` and Rack form caches. Rails request-parameter caches are omitted
entirely by the `action_dispatch.*` whitelist. Custom
middleware data under other keys is not inferred to be a body cache.

Otherwise the body reader reads **at most 102,401 bytes**, returns at most **102,400 bytes
(100 KiB)**, and uses the extra byte to detect truncation. It reads from the
stream's current position, handles short reads, and never rewinds, drains,
closes or parses `rack.input`. A stream consumed by earlier middleware cannot
necessarily be reconstructed when no raw body cache is available. Content-Length is reported but not trusted to
establish how many bytes were actually available.

Text is returned as UTF-8; binary/invalid-UTF-8 bodies use Base64, with explicit
encoding, source, byte counts and truncation fields. With a cached body,
`bytes_read` is zero and `cached_bytes` reports the original buffered size. Base64 and JSON overhead are not
part of the 100 KiB input-byte limit. A truncation inside a UTF-8 character uses
Base64 so no captured byte is silently discarded.

Other invalid-UTF-8 strings are represented by a tagged Base64 object rather
than lossy replacement. Non-finite floats such as NaN/Infinity are tagged rather
than causing JSON generation to fail. Integer/symbol object keys become JSON
strings where unambiguous; unsupported or colliding keys use a tagged entries
list. Cycles are marked. Application objects and Hash/Array subclasses are
opaque class descriptions, not `inspect`, `to_h`, `as_json` or `to_json` output;
this avoids materializing lazy sessions and other application state.

Defensive normalization is bounded to depth 24 and 100,000 nodes per normalized
field, with explicit limit markers. Ordinary header/environment string values
have no separate truncation limit. Known local files, including an opt-in
authentication file, are bounded to 64 KiB,
and allocator map scanning to 2 MiB. An oversized local
file is reported as unavailable, not silently parsed as a complete file.

### Failures and response lifetime

Ordinary collector failures, including unavailable optional libraries/APIs,
produce a partial **200** response with entries under `errors` when that category
is selected. Missing optional
APIs may simply be omitted; YJIT unavailability is explicit. A collector returning
`null` is not reinterpreted as zero or disabled. Fields are a human-facing format,
not a versioned schema contract.

A last-resort ordinary snapshot/JSON failure produces a static JSON **500**
response. Error reporting does not invoke Rails logging. `NoMemoryError`,
`SystemExit`, `Interrupt` and other fatal/non-ordinary exceptions are not
swallowed. A killed, wedged or exhausted worker cannot be rescued by this gem.

Snapshots, selection rules and normalizers are request-local. No full snapshot, environment,
request, exception object or response history is retained in module/class
state. The Rack response body holds only the final JSON string; `close` clears
that reference even if the response object remains reachable. During `each`, a
local reference ensures that concurrent `close` cannot change the chunk to `nil`;
that reference expires after iteration. Rack servers and
middleware must close it. The gem never calls `GC.start`, changes GC settings,
compacts the heap, or enables/resets YJIT/statistics. Reclaimable Ruby objects do
not imply immediate GC or a reduction in RSS.

## Meaning of "read-only"

The gem performs observation, not business operations or persistent application
configuration changes. It is not literally free of effects: Ruby files must be
loaded, some standard-library activation can persist after the first diagnostic
request, collection/serialization allocates objects and consumes CPU, files may
acquire access-time changes, and reading the request body advances its stream.
Optional authentication also reads its password file and performs digest work.
An explicitly requested `sleep` deliberately occupies serving capacity before
collection; it is the only intentional delay feature and is never enabled by
default.
Normal allocations can trigger ordinary GC/JIT activity. Kernel accounting and
some runtime accessors also perform work. These are not hidden guarantees of
zero overhead or zero initialization inside Ruby itself.

All observations concern the **worker serving this request**, and collection is
not atomic. GC counters can include state inherited from a preloader. Linux
process age comes from the current process rather than gem load time, so no
fork callback is required. The estimated wall-clock start time is approximate.
FD counts include diagnostic activity; memory counters can change while read.
PSS/`smaps_rollup` can be unavailable on older kernels or under restrictions.
Allocator-library mappings are hints only, not proof of the allocator in use.
No processed-request counter is synthesized.

There are deliberately no asynchronous timeouts or worker-killing mechanisms.
A slow request-body stream or filesystem (including the authentication file) can
still block. Set request-body size,
read-time and concurrency limits at the proxy/server. Use this endpoint
occasionally; it is not a high-frequency monitoring or liveness endpoint.

## Development and checks

Standalone tests require an installed, compatible Minitest, but neither Rails
nor Rack nor Bundler is necessary to run them:

```sh
ruby script/test
```

The development Gemfile pins test-tool ranges compatible with the Ruby 2.4
target. `script/test` also works with a suitable already-installed newer
Minitest on a newer Ruby. No dependency installation happens automatically.

An optional standalone Rack::Lint smoke script is provided for environments
where Rack is already installed. It does not boot Rails:

```sh
ruby script/rack_lint
```

A specific installed Rack version can be selected:

```sh
RACK_VERSION=2.2.9 ruby script/rack_lint
```

An optional Bundler-only smoke script verifies both automatic loading via
`Bundler.require` and explicit loading after `Bundler.setup`, using temporary
local path-gem Gemfiles, including optional authentication, request delays and inventories. It never boots Rails,
installs gems, or fetches sources:

```sh
ruby script/bundler_smoke
```

Read [AGENTS.md](AGENTS.md) before changes. See [design notes](docs/DESIGN.md) for
implementation boundaries and [validation](docs/VALIDATION.md) for known gaps.
Do not store live diagnostic output in this repository: it contains secrets.

## Distribution and license

No public distribution license has been selected; see [LICENSE](LICENSE).
The gemspec sets a deliberately non-routable `allowed_push_host` to help prevent
accidental publication. The owner must select an appropriate private registry
configuration or public license before publishing. No remote Git host is assumed.
A Git bundle carries commits/refs, not the source repository's local Git config.

### Full and incremental bundles

The full `rails_runtime_info-0.7.1-full.bundle` can be cloned into an empty
location using the command above. It includes `main`, `v0.7.1` and all previous
history/tags.

The smaller `rails_runtime_info-0.7.1-incremental.bundle` requires the existing
commit `6c327e62f3e16ebc61a5704c9e64540cc742c950` (v0.7.0) and its history. It
contains only the new history plus the `main` and `v0.7.1` refs; it cannot be
cloned into an empty repository. From a clean existing checkout on the branch
you intend to update, with the bundle in its parent directory:

```sh
git bundle verify ../rails_runtime_info-0.7.1-incremental.bundle
```

```sh
git fetch ../rails_runtime_info-0.7.1-incremental.bundle refs/heads/main refs/tags/v0.7.1:refs/tags/v0.7.1
```

```sh
git merge --ff-only v0.7.1
```

The fast-forward requirement refuses a diverged branch rather than rewriting
local work. Existing bare-endpoint routes stay unauthenticated; protection is
only enabled by explicitly using the route wrapper. Sleep is zero by default
and can only be requested through the diagnostic query string.
