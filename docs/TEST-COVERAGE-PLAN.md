# pz Test-Coverage Plan

Goal: **100% meaningful coverage** of the pz Zig 0.16 codebase (155 files, ~101K LOC, 1783 existing tests). This document is the backlog. It enumerates every coverage gap surfaced by the per-area audits, grouped by area and priority, with a phased rollout and concrete done-criteria.

## Principle: meaningful tests only

A useful test proves behavior the **compiler cannot**: error paths, edge cases, integration contracts, security boundaries. We do **not** write tests that verify comptime-guaranteed behavior, constants, getters, type correctness, or "the enum has 5 variants". Those are noise — they inflate the count and rot.

Concretely, skip:
- Tests that re-assert a `const` value or an enum's cardinality.
- Tests that a pure-comptime `switch` is exhaustive (the compiler enforces it). Where the audit asks for "exhaustiveness", the *meaningful* version is a **mutation/behavior** test: prove each arm is actually reached and produces distinct observable output, not that the arm exists.
- Trivial round-trips of plain-old-data with no transform.

Keep everything that exercises a guard, a boundary, an error return, a security check, or a multi-component contract.

## The 5 test categories

| Category | Definition | Tool |
|---|---|---|
| **unit** | One function, one branch/boundary/error path. `expectEqual` for scalars, `ohsnap` for structs. | `zig build test` |
| **functional** | One component across multiple calls / state transitions / I/O. | `zig build test` |
| **regression** | Locks a *known* past bug (every `P0-1`/`MP2-R1`-style comment is a regression contract). | `zig build test` |
| **e2e** | Real `pz` binary or full pipeline; PTY keyboard + mock terminal for TUI. | `zig build test` + `src/test/pty_harness.zig` |
| **mutation** | Proves a specific guard is *checked*, not dead code. The audit's mutation entries ARE the spec (flip `<`→`<=`, drop a `saw_stop=true`, short-circuit `evaluate()`→`.allow`; the named test must fail). | manual mutation list (see infra) |

UX rows require BOTH mock-terminal and PTY layers per `CLAUDE.md`.

---

## Summary table

Per area: existing tests, then gap counts by category, then by priority.

| Area | Existing | unit | func | regr | e2e | mut | **P0** | **P1** | **P2** | Gaps |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| core (agent/policy/audit/signing/shell/fs/lru/watcher/syslog/…) | 237 | 30 | 4 | 0 | 0 | 3 | 8 | 27 | 0 | **35** |
| core/providers | 279 | 26 | 13 | 4 | 5 | 4 | 8 | 42 | 1 | **52** |
| core/session (schema/serialize/export) | 99 | 19 | 16 | 0 | 0 | 0 | 4 | 26 | 5 | **35** |
| core/tools (dispatch/plugins/path_guard) | 134 | 27 | 8 | 0 | 0 | 0 | 2 | 23 | 10 | **35** |
| app (config/cli/args/bg/journal/runtime/update/report) | 312 | 51 | 7 | 0 | 0 | 0 | 22 | 37 | 0 | **59** |
| app/print + modes/rpc | — | 53 | 3 | 0 | 0 | 0 | 3 | 36 | 17 | **56** |
| modes/tui-a (cmdpicker/input/keybindings/harness/frame/panels) | 155 | 28 | 13 | 0 | 0 | 0 | 5 | 31 | 5 | **41** |
| modes/tui-b (overlay/image/theme/color_detect/fuzzy/vscreen) | 69 | 35 | 0 | 0 | 0 | 0 | 2 | 31 | 2 | **35** |
| perf + test-infra (src/perf/*, src/test/*) | 81 | 27 | 2 | 0 | 0 | 3 | 1 | 27 | 4 | **32** |
| **TOTAL** | **1783** | **296** | **66** | **8** | **10** | **17** | **55** | **280** | **44** | **380** |

> Counts are post-dedup at the area level; cross-area duplicates (e.g. UTF-8 lossy sanitization appears in core, session, app, tui) are merged in the per-area sections and counted once in the phase totals below.

---

## Test-infrastructure gaps

pz's `build.zig` currently exposes five steps: `build`, `run`, `test`, `perf`, `check`. There is **NO** `fuzz` step, **NO** coverage measurement, and **NO** mutation harness. `src/perf/fuzz.zig` is a throughput *gate*, not a `std.testing.fuzz` target. We close these:

### 1. `fuzz` step — wire `std.testing.fuzz` targets

Add `b.step("fuzz", ...)` that builds a dedicated test binary with the fuzz targets the audits demand. Zig 0.16 ships an in-tree fuzzer; targets use the `std.testing.fuzz(context, oneInput, .{})` form. Author per the **`zig-fuzz-target`** skill (`~/.agents/skills/zig-fuzz-target`).

Priority fuzz targets (all from the audits):
- `policy.matchGlob` / `matchPath` — exponential backtracking pathology (`a*b*c*…`).
- `stream_parse.Parser.feed/finish` — SSE split at random byte boundaries; reconstruct == unsplit baseline.
- `fuzzy.score` — pure/deterministic; integer-division off-by-one in consec/gap/position math.
- `tools/plugin.parseList` + `parseFrontmatter` — random UTF-8 + bracket syntax.
- `print/format.sanitizeOutput` and `vscreen.feed` / `ansi_ast.parseCsi/parseOsc` — truncated CSI/OSC must never overrun or loop.
- `session/export.atomicExportStream` — path-traversal / symlink input corpus.
- `color_detect.rgbTo256` — property: cube vs grayscale ramp choice is stable near the boundary.

### 2. `coverage` step — measure with kcov

Add `b.step("coverage", ...)` that runs **kcov** over the test binary to produce line+branch coverage (`kcov --include-pattern=src/ out/cov ./zig-out/bin/test`). Install kcov via nix-darwin (not Homebrew). This *measures* the 100%-meaningful target — uncovered lines after Phase A/B are either a missing test or a justified `// coverage: comptime-only` exclusion. Coverage is the audit's feedback loop, not a gate to game.

### 3. Mutation approach — the audit IS the mutation spec

Zig has no off-the-shelf mutator. We do **manual, recorded mutation tests**: each `category: mutation` entry below names the exact source mutation (file:line, `<`→`<=`, remove `saw_stop=true`, short-circuit `evaluate()`→`.allow`) and the test that must fail. The procedure per the **`zig-testing-patterns`** skill (`~/.agents/skills/zig-testing-patterns`):
1. Apply the mutation locally.
2. Run the named test; confirm it **fails** (mutation killed).
3. Revert. Record the kill in `docs/MUTATION-KILLS.md`.

A mutation entry that survives means the test is too weak and must be strengthened before the entry is checked off.

### 4. Reusable harnesses to build (referenced by many rows)

- **Policy-boundary fixture** — temp `policy.json` with specific lock bits + rules; shared across `app/config`, `app/runtime`, `core/policy`.
- **Audit-event assertion helper** — capture emitter calls and assert exact fields (`ts_ms`, `sid`, `severity`, `outcome`, `msg`). Used by `bg.zig`, `runtime.zig`, `export.zig`.
- **Allocation-failure (OOM) allocator** — drives `dupe`/`encodeAlloc`/export `writeHtmlHeadMeta` error paths; detects leaks on error.
- **TOCTOU race injector** for `path_guard` — swap a file between `openat` and `fstat`; verify `ensureStableFile` catches inode/dev change.
- **Mock-PTY queue** for `input.zig` — paste-while-reading, resize mid-parse, dual notify-fd readiness.
- **Frame-snapshot helper** — extract `rowAscii` / `trimmedBoxSegmentsAlloc` to `src/test/` for reuse across TUI render tests.
- **Error-injection harness** for `http_mock`/`syslog_mock`/`provider_mock` — exercise `InvalidResponseCount`, `FrameTooLarge`, `InvalidFrame`, pipe/fcntl failures.

---

## Per-area checklists

Format: `- [ ] file::target — [CATEGORY/Pn] behavior (rationale)`. Grouped by priority within each area.

### core — agent / policy / audit_integrity / signing / shell / fs_secure / lru / context / resource / watcher / syslog

**P0**
- [ ] `core/signing.zig::KeyRing.resolveAt` — [unit/P0] rejects expired and revoked keys with the right error; happy path only today (trust-anchor enforcement)
- [ ] `core/signing.zig::ctEql` — [mutation/P0] returns false for equal-length mismatch with no early exit; an early-return mutation must be killed (timing side-channel)
- [ ] `core/policy.zig::GenerationState.load` — [unit/P0] rejects negative generation, returns 0 for non-integer (rollback detection needs monotonicity)
- [ ] `core/shell.zig::deniedByPolicy` — [unit/P0] returns deny on any parse error except OutOfMemory; error must not leak an allow (fail-closed)
- [ ] `core/fs_secure.zig::validateLeaf` — [unit/P0] rejects `.`, `..`, empty, and any `/`, `\`, NUL (confined-dir traversal)
- [ ] `core/agent.zig::Stub.recv` — [unit/P0] rejects `frame.seq <= recv_seq`; `<=`→`<` mutation (allows equality replay) must be killed
- [ ] `core/syslog.zig::Sender.init` — [unit/P0] rejects private/reserved IPv4 (10/172.16–31/192.168/127/224+) and IPv6 unless `allow_private`; boundary 172.16 & 172.31 must fail (exfil egress block)

**P1**
- [ ] `core/time.zig::milliTimestamp/microTimestamp/nanoTimestamp` — [unit/P1] monotonic, and `clock_gettime` failure does not yield negative/zero silently
- [ ] `core/signing.zig::PublicKey.parseText` — [unit/P1] rejects malformed SSH keys (bad name, missing base64); `readSshStr` bounds at offset transitions
- [ ] `core/signing.zig::PublicKey.parsePem` — [unit/P1] rejects wrong SPKI prefix length / payload mismatch; exact-sized buffer edge
- [ ] `core/policy.zig::matchGlob` — [unit/P1] overlapping stars `a*b*c` vs `aabbcc` backtracking
- [ ] `core/policy.zig::evaluateKind` — [functional/P1] tool+kind filters are AND: a rule matches only if both match
- [ ] `core/policy.zig::isBlockedIp4` — [unit/P1] class E (224–255), RFC1918, link-local 169.254, 100.64–127 boundaries
- [ ] `core/policy.zig::isBlockedIp6` — [unit/P1] IPv4-mapped extraction `::ffff:192.168.1.1` prefix + boundary
- [ ] `core/policy.zig::EgressPolicy.validatedProxy` — [unit/P1] host extraction from http(s) URL, case-insensitive match, malformed-after-scheme rejection
- [ ] `core/policy.zig::parseDoc` — [unit/P1] fails closed on unknown top-level keys (tamper/version hardening)
- [ ] `core/audit_integrity.zig::verifyLogAlloc` — [unit/P1] rejects log not ending in newline (truncation detection)
- [ ] `core/audit_integrity.zig::SeqTracker.persist` — [unit/P1] create/truncate/write errors leave no partial state (no replay window)
- [ ] `core/audit_integrity.zig::parseNibble` — [mutation/P1] rejects `g`–`z`, `{`–`~`; removing the char-validation `else` must be killed
- [ ] `core/shell.zig::commandTouchesProtectedPath` — [unit/P1] stops recursion at depth ≥ 8 and returns false (nesting-attack limit)
- [ ] `core/shell.zig::scanCmd` (tokenize) — [mutation/P1] unterminated quote returns error; dropping the closing-quote check must be killed
- [ ] `core/fs_secure.zig::createConfined` — [unit/P1] `exclusive=true` skips redundant hardlink stat (nlink=1 guaranteed)
- [ ] `core/fs_secure.zig::atomicWriteAt` — [functional/P1] cleans stale `.tmp` before exclusive create; crash-recovery path
- [ ] `core/lru.zig::Lru` eviction — [mutation/P1] tied ages evict insertion-order-first; `<`→`<=` must be killed
- [ ] `core/context.zig::load` — [functional/P1] returns null context when policy lock has `context=true`
- [ ] `core/context.zig::assemblePartsWithBudget` — [unit/P1] mid-part budget exhaustion truncates + marker without secondary overflow
- [ ] `core/resource.zig::parseFrontmatter` — [unit/P1] strips BOM, handles `\n` and `\r\n` fences, fence at EOF without newline
- [ ] `core/watcher.zig::watchLoop` — [functional/P1] polls atomic stop flag and drains event queue before exit (no stop/event race)
- [ ] `core/watcher.zig::Backend.ensurePath` — [unit/P1] caches fd; `drop()` closes fd and nullifies entry (no fd leak)
- [ ] `core/agent.zig::Stub.run/cancel` — [unit/P1] reject when state ≠ idle / ≠ running (protocol state)
- [ ] `core/agent.zig::encodeAlloc` — [functional/P1] decode round-trips all message types (hello/run/out/done/err)
- [ ] `core/agent.zig::closeInheritedFds` — [unit/P1] closes all fds except keep_fd and std{in,out,err} (child isolation)
- [ ] `core/syslog.zig::Message.validate` — [unit/P1] rejects hostname>255, app_name>48, procid>128, msgid>32, negative timestamp (RFC 5424)
- [ ] `core/syslog.zig::validateSdName` — [unit/P1] rejects space/`=`/`]`/`@`; allows PRINTUSASCII + hyphen

### core/providers

**P0**
- [ ] `oauth_flow.zig::exchangeAuthorizationCode` — [functional/P0] non-200 error JSON yields clean auth error, not silent swallow
- [ ] `oauth_flow.zig::refreshOAuthForProvider` — [functional/P0] expired/invalid refresh token → `error.RefreshFailed`, no cascade into new OAuth flow
- [ ] `oauth_callback.zig::parseCallbackQuery` (state) — [unit/P0] rejects code with mismatched state (CSRF)
- [ ] `oauth_callback.zig::parseCallbackQuery` (error) — [unit/P0] surfaces `error_description` from `?error=access_denied`, not silent drop
- [ ] `http_client.zig::retryLoop` (401+OAuth) — [functional/P0] refresh called once, never again on recurring 401 (no refresh loop / account lock)
- [ ] `stream_parse.zig::Parser.finish` — [unit/P0] `error.MissingStop` when no stop event ever seen (dropped connection)
- [ ] regression MP2-R1 — [regression/P0] `tool_call\nstop` with no `usage` parses; usage defaults `0|0|0`
- [ ] regression MP3-R1 — [regression/P0] `loadForProviderWithHooks(.openai)` must NOT fall back to Anthropic creds when both exist (provider isolation)

**P1** (selected; full set below)
- [ ] `http_client.zig::RealSleeper.sleep` — [functional/P1] cancel_fd during backoff returns <10ms
- [ ] `http_client.zig::retryLoop` (401, api_key) — [unit/P1] fails immediately, status preserved, no retry
- [ ] `http_client.zig::extractJsonErrMsg` — [unit/P1] correctly extracts message with escaped quotes; no mis-scan
- [ ] `http_client.zig::sanitizeUtf8` — [unit/P1] invalid bytes → `?` each; valid UTF-8 unchanged *(shared with core/session/app — single impl, test here)*
- [ ] `stream_parse.zig::split3` — [unit/P1] `a||b`→`['a','','b']`; `a|`→`error.BadFrame`
- [ ] `stream_parse.zig::parseU64` — [unit/P1] overflow value → `error.InvalidUsage`, not saturation
- [ ] `config.zig` wildcard — [unit/P1] longest-prefix wins: `ab*` over `a*` for `abc`
- [ ] `config.zig::validate` — [unit/P1] rejects empty name, `ctx_win=0`, interior `a*b`
- [ ] `auth_load.zig` migration — [functional/P1] `~/.pi/agent/auth.json` → `~/.pz/auth.json` atomically; 2nd load uses primary
- [ ] `auth_load.zig::loadFileAuthForProvider` — [unit/P1] primary rejects unknown fields, legacy ignores them
- [ ] `auth_load.zig::authFromEnv` — [unit/P1] OAuth precedence over API key when both env vars set
- [ ] `client.zig::Router.routerStart` — [unit/P1] `error.NoBackend` when lookup null (no silent fallback)
- [ ] `client.zig::Router` suffix — [functional/P1] `gpt-5:openai` → backend sees bare `gpt-5`
- [ ] `client.zig::streamRun` cancel — [functional/P1] cancel between chunk reads → `error.TransportFatal` immediately
- [ ] `client.zig::streamRun` parser error — [unit/P1] BadFrame/UnknownTag/InvalidUsage stop retry immediately
- [ ] `registry.zig::resolveProvider` — [unit/P1] case-sensitive: `Anthropic`→null, `anthropic`→info
- [ ] `retry.zig::Backoff.delayMs` — [unit/P1] `delayMs(0)`→`error.InvalidFailureCount`; `delayMs(1)`→base (1-indexed)
- [ ] `retry.zig::Backoff.mulCap` — [unit/P1] base=1, max=u64::MAX, mul=65536 caps at max, no overflow
- [ ] `types.zig::isOverflowError` — [unit/P1] malformed/empty JSON → false, no crash
- [ ] `anthropic.zig::parseSseData` tool_use — [functional/P1] args preserved across START/DELTA/END events
- [ ] `anthropic.zig::buildBody` cache_control — [unit/P1] injects `{type:ephemeral}` into first system msg only when enabled
- [ ] `anthropic.zig::buildBody` merge — [unit/P1] consecutive same-role merged (`user a` + `user b` → `a\nb`)
- [ ] `anthropic.zig::buildBody` thinking — [unit/P1] budget capped at `ctx_win - used`, not raw value
- [ ] `openai.zig::parseSseData` — [unit/P1] extracts content from `choices[0].delta.content`
- [ ] `openai.zig::buildBody` — [unit/P1] enforces user-first alternation; merge or error
- [ ] `api.zig::resolveDispatch` — [unit/P1] explicit `provider` field overrides model suffix
- [ ] `proc_transport.zig::buildReq` — [unit/P1] exact wire JSON, no extra fields
- [ ] `compat.zig::mapToOpenAiCompat` — [unit/P1] role mapping incl. tool→`tool`
- [ ] `oauth_callback.zig::parseCallbackQuery` (malformed) — [unit/P1] `?code=x&state&code=y` extracts first code defensively
- [ ] e2e auth resolution — [e2e/P1] `HOME=/tmp`, no env creds → loads `~/.pz/auth.json` → correct provider
- [ ] e2e 429 backoff — [e2e/P1] 429 → backoff N ms → 200; verify timing
- [ ] e2e chunk reassembly — [e2e/P1] SSE split at 500 random boundaries == unsplit baseline
- [ ] e2e Router dispatch — [e2e/P1] `gpt-5:openai` routes to OpenAI, streams parse correctly
- [ ] mutation saw_stop — [mutation/P1] removing `saw_stop=true` (line 104) → `finish()` must `MissingStop`
- [ ] mutation retryable — [mutation/P1] removing `retryable()` check (line 94) → non-transient returns `.fail`
- [ ] mutation longest-prefix — [mutation/P1] forcing first-match in wildcard loop fails overlapping-pattern test

**P2**
- [ ] `config.zig::Config.find` — [unit/P2] 1000 exact + 100 wildcard lookup <1ms (proves hash probe, not O(n))

### core/session — schema / writer / reader / export / compact / retry_state / stores / path / session_file

**P0**
- [ ] `schema.zig::decodeSlice` — [unit/P0] rejects version `< current` and `> current`, not just `!=` (version creep → data loss)
- [ ] `reader.zig::ReplayReader.next` — [unit/P0] invalidates prior event's string slices; stale-pointer use must fail under GPA (UAF guard)
- [ ] `export.zig::atomicExportStream` — [unit/P0] uses `fs_secure.atomicWriteAtFn`; symlink output (`ln -s ~/.ssh/id_rsa out.md`) is not followed
- [ ] `path.zig::validateSid` — [unit/P0] rejects NUL in the middle, not only empty

**P1**
- [ ] `schema.zig::sanitizeData/sanitizeGitMeta/sanitizeEntryMeta` — [unit/P1] invalid UTF-8 in nested fields replaced lossy; re-encode never fails
- [ ] `schema.zig::encodeAlloc`+`dupe` — [unit/P1] round-trip byte-identical under near-capacity allocator
- [ ] `writer.zig::Writer.append` — [functional/P1] sync failure after partial write keeps state valid for next append
- [ ] `writer.zig::Writer` seek — [unit/P1] `seekEnd` before each write; truncate-mid-line then append starts fresh
- [ ] `reader.zig::ReplayReader.next` line_too_long+EOF — [unit/P1] returns `ReplayLineTooLong` with correct line_no, not `TornReplayLine`
- [ ] `reader.zig::ReplayReader` boundary — [unit/P1] exactly `max_line_bytes` passes; `+1` fails (`>` not `>=`)
- [ ] `reader.zig::ReplayReader` null optionals — [functional/P1] `"git_meta":null` decodes identically to omitted
- [ ] `export.zig::htmlEscapeAlloc` — [unit/P1] `& < >` in `.text`; plus `"` `'` in `.attr`; OWASP XSS vectors
- [ ] `export.zig::writeHtmlHeadMeta` — [unit/P1] malformed-line error from `gscan.next()` propagates; export fails loudly
- [ ] `export.zig::fenceLen` — [unit/P1] 20-backtick payload → fence length 21, wraps safely
- [ ] `export.zig::exportWith` null emitter — [unit/P1] `audit_emitter=null` → `emitAudit` no-op, export succeeds
- [ ] `export.zig::exportWith` path — [functional/P1] relative `out_path` resolved vs cwd; absolute used as-is
- [ ] `regress.zig` — [functional/P1] compaction preserves `retry_state.json` (reloadable, not corrupted)
- [ ] `regress.zig` — [functional/P1] 100 noop + 1 real event compacts to 1; replay yields only real
- [ ] `regress.zig` — [functional/P1] corrupt `.compact.json` (no trailing newline) → `error.TornCheckpoint`, re-compaction allowed
- [ ] `null_store.zig` — [unit/P1] replay always `error.FileNotFound`, even after appends (stateless)
- [ ] `fs_store.zig` — [functional/P1] custom replay opts (`max_line_bytes=100`) enforced independent of flush policy
- [ ] `fs_store.zig::OwnedReplay.deinit` — [unit/P1] releases wrapped `ReplayReader`, no double-free/UAF
- [ ] `compact.zig::run` — [functional/P1] mid-write failure leaves `.compact.tmp` behind (manual cleanup), not silently deleted
- [ ] `compact.zig::run` — [functional/P1] re-compacting already-compact session is a no-op (idempotent)
- [ ] `compact.zig::loadCheckpoint` — [unit/P1] rejects version ≠ `checkpoint_version`
- [ ] `retry_state.zig::save` — [unit/P1] rejects `fail_count > tries_done` before write
- [ ] `retry_state.zig::load` — [unit/P1] rejects corrupt `fail_count > tries_done` → `error.InvalidRetryState` (defense in depth)
- [ ] `session_file.zig::File.init` — [unit/P1] created-then-`deinit`-without-`close` deletes; failed init `deinit` safe

**P2**
- [ ] `writer.zig::Writer` flush wraparound — [unit/P2] `pending` u32 no overflow at 65536+ appends with `every_n=2`
- [ ] `export.zig` truncation — [unit/P2] `tool_result` exactly 2000 bytes not truncated; 2001 truncated with suffix
- [ ] `export.zig::writeHtmlEscaped/writeHtmlAttr` — [unit/P2] empty string → no output, no alloc
- [ ] `session_file.zig::cleanOrphanTmpFiles` — [functional/P2] permission error mid-iterate stops gracefully, no crash

### core/tools — plugin / builtin / path_guard / registry / runtime

**P0**
- [ ] `tools/builtin.zig::runWeb` — [functional/P0] redacts secrets from `approval_required` message before returning to model (creds in auth URLs)
- [ ] `tools/plugin.zig` Dispatch.Bind vtable — [unit/P0] `@fieldParentPtr` casts back to Runtime correctly and calls `dispatchRun` (type-erasure UB if wrong)

**P1**
- [ ] `plugin.zig::parseList` — [unit/P1] rejects unmatched brackets / empty comma seq (`[a, b`, `a, b]`, `[a,, b]`)
- [ ] `plugin.zig::parseFrontmatter` — [unit/P1] rejects BOM+invalid UTF-8 and invalid UTF-8 after frontmatter block
- [ ] `plugin.zig::discover` — [functional/P1] permission denial on a specific plugin subdir/file is surfaced, not silently skipped
- [ ] `plugin.zig::discoverStrict` — [unit/P1] no plugin leak when a blocked plugin returns `PluginToolDenied` (deinit on error path)
- [ ] `plugin.zig::Runtime.dispatchRun` — [unit/P1] rejects `Call.args` tag ≠ `.bash` → `InvalidArgs`
- [ ] `builtin.zig::rebuildEntries`+`activeEntries` — [unit/P1] subset matches `tool_mask` deterministically across all mask combos; no dup/skip
- [ ] `builtin.zig::dispatchRun` — [unit/P1] rejects mismatch between `call.kind` and args union tag (e.g. `.read` kind + bash args)
- [ ] `builtin.zig::runAsk` — [functional/P1] hook errors map to `.failed`/`.io`; cancelled-JSON detection on raw_msg
- [ ] `builtin.zig::activeEntries` — [unit/P1] never writes beyond `selected[10]` for any `tool_mask`
- [ ] `builtin.zig::askResultCancelled` — [unit/P1] non-JSON / missing field → false, no crash
- [ ] `path_guard.zig::CwdGuard` — [functional/P1] restores + unlocks even if `setDirAsCwd` fails during restore (no deadlock)
- [ ] `path_guard.zig::openParentDir` — [unit/P1] trailing sep / `.` / `..` components yield correct leaf
- [ ] `path_guard.zig::relPath` — [unit/P1] rejects absolute paths resolving outside cwd via symlink/mount
- [ ] `path_guard.zig::relPath` substring — [unit/P1] `cwd=/foo/foobar`, `path=/foo/foo` denied via `isSep(path[root.len])`
- [ ] `path_guard.zig::resolveConfined` — [unit/P1] loop terminates after all hops; alloc failure propagates
- [ ] `path_guard.zig::resolveConfined` hops — [unit/P1] symlink chain > 40 (`max_hops`) → `AccessDenied`; counter increments before check
- [ ] `path_guard.zig::ensureStableFile` — [functional/P1] detects different inode/dev after `openat` (TOCTOU)
- [ ] `path_guard.zig::mapParentDirErr` — [unit/P1] distinguishes non-dir vs symlink via `fstatat` `AT.SYMLINK_NOFOLLOW`
- [ ] `registry.zig::Registry.run` — [unit/P1] `KindMismatch` before invoking dispatch
- [ ] `registry.zig::Registry.run` — [unit/P1] dispatch errors (incl. `OutOfMemory`) propagate, not masked
- [ ] `runtime.zig::Registry.run` — [unit/P1] `start` event emitted before `dispatch.run`, even on error
- [ ] `runtime.zig::Registry.run` — [unit/P1] no `output` event when `result.out_streamed=true` (no double emit)
- [ ] `runtime.zig::Registry.run` — [functional/P1] `finish` event fires even if `output` emission fails

**P2**
- [ ] `plugin.zig::deniedRequirement` — [unit/P2] empty `requires_tools` → null even when policy denies all
- [ ] `plugin.zig::Runtime.entrySlice` — [unit/P2] cache idempotent on repeat calls
- [ ] `plugin.zig::findClosingFence` — [unit/P2] CRLF `---` recognized before buffer-boundary check
- [ ] `plugin.zig::parseKV` — [unit/P2] whitespace-only key (`   : value`) → null
- [ ] `plugin.zig::discover` — [unit/P2] `home=null` → empty `Loaded`, not error
- [ ] `builtin.zig::maskForName` — [unit/P2] unknown names (`foobar`, `read_x`) → null *(meaningful: proves the StaticStringMap actually contains all 11 names)*
- [ ] `runtime.zig::validateTypes` — [unit/P2] rejects Event missing start/output/finish, Call missing kind/at_ms, Result missing out *(comptime — keep only as a `@compileError`-triggering doc test, not a runtime test)*

### app — config / cli / args / bg / job_journal / runtime / update / report

**P0**
- [ ] `config.zig::discover` system_prompt lock — [unit/P0] policy-locked `system_prompt` rejects `--append-system-prompt` and `--system-prompt`
- [ ] `config.zig::validateHome` — [unit/P0] returns null for empty string and for relative paths
- [ ] `config.zig::Env.fromMap` — [unit/P0] env value with embedded NUL flows through but `validateHome` (and callers) reject it
- [ ] `cli.zig::parse` — [unit/P0] `error.MissingPrintPrompt` when print mode lacks prompt (exercised directly from `parse`)
- [ ] `args.zig::parseToolMask` — [unit/P0] `error.InvalidTool` on empty-after-trim (`read,,bash`)
- [ ] `args.zig::parseMode` — [unit/P0] `error.InvalidMode` for unrecognized string
- [ ] `args.zig::parse` `--thinking` — [unit/P0] `error.InvalidThinking` for all invalid forms
- [ ] `args.zig::parse` `--max-turns` — [unit/P0] rejects `> u16::MAX`
- [ ] `bg.zig::Manager.start` protected path — [unit/P0] rejects via `touchesProtectedPath` AND emits audit fail
- [ ] `bg.zig::Manager.start` policy — [unit/P0] `deniedByPolicy` true emits audit denial
- [ ] `bg.zig::Manager.deinit` — [unit/P0] SIGKILL running jobs, journal cleanup, threads join, allocs freed
- [ ] `runtime.zig::parseNativeProviderKind` — [unit/P0] null for unknown provider
- [ ] `runtime.zig::DynamicKind.fromNative` — [unit/P0] null for anthropic/openai, non-null for dynamic
- [ ] `runtime.zig::DynamicProvider.lookup` — [unit/P0] null when resolved name ≠ backend kind (no silent reroute)
- [ ] `runtime.zig::RuntimePolicy.allowsTool` — [unit/P0] 256-byte `bufPrint` overflow → returns false (no heap overflow)
- [ ] `runtime.zig::PolicyToolDispatch.run` — [unit/P0] `.denied` result when `allowsTool` false (denial never reaches inner dispatch)
- [ ] `runtime.zig::PolicyToolAuth.check` — [unit/P0] emits deny audit before `error.PolicyDenied`
- [ ] `runtime.zig::InputWatcher.watchFn` — [unit/P0] stops writing to stash at `cur == stash.len` (buffer overrun guard)
- [ ] `runtime.zig::sanitizeUtf8LossyAlloc` — [unit/P0] each byte of an incomplete trailing UTF-8 sequence replaced *(canonical impl; shared with TuiSink/PrintSink)*
- [ ] `runtime.zig` NativeProviderRuntime/DynamicProvider switches — [mutation/P0] each arm reached and produces distinct output (behavioral exhaustiveness, not type-level)

**P1**
- [ ] `config.zig::loadGlobalSettings` — [unit/P1] null on NUL in home; rejects non-absolute `home + auto_cfg_path`
- [ ] `config.zig` SyslogFwd — [unit/P1] `syslog_host/port/transport` round-trip; invalid transport errors; defaults 514/`udp`
- [ ] `config.zig::discover` lock propagation — [functional/P1] `policy.lock` and `audit_overflow` copied into Config
- [ ] `cli.zig::parse` errdefer — [unit/P1] `config.deinit()` on `discover()` failure (no leak)
- [ ] `args.zig::ThinkingLevel.toProviderOpts` — [unit/P1] every level maps to correct `Opts` thinking+budget (behavioral, not the constants)
- [ ] `args.zig` thinking_map/mode_map — [unit/P1] all aliases (off/none/disabled/min/med/max/auto; tui→interactive) reachable end-to-end
- [ ] `bg.zig::Manager.start` trim — [unit/P1] whitespace-only `cmd_raw` rejected after trim
- [ ] `bg.zig::Manager.initWithOpts` — [functional/P1] `recover:true` replays and fully clears stale journal entries
- [ ] `bg.zig::Manager.stop` — [unit/P1] SIGTERM to `-pid` (POSIX) / pid (Windows)
- [ ] `bg.zig::Manager.start` success audit — [functional/P1] control audit `outcome:success` recorded
- [ ] `bg.zig::Manager.emitControlAudit` — [unit/P1] `audit_seq` `+%=` wraparound never duplicates in session
- [ ] `job_journal.zig::replayActive` malformed — [unit/P1] skips malformed JSON lines (catch continue) without leak
- [ ] `job_journal.zig::replayActive` dup IDs — [unit/P1] removes old entry on repeated ID
- [ ] `job_journal.zig::init` — [unit/P1] opens append (`read:true, truncate:false`) then `seekEnd`; dir via `fs_secure.ensureDirPath` secure mode
- [ ] `job_journal.zig::appendLine` — [functional/P1] partial write failure surfaces for caller retry
- [ ] `runtime.zig::RuntimePolicy.allows` — [unit/P1] true when unenforced; evaluates rules when enforced
- [ ] `runtime.zig::oauthExpiredTag` — [unit/P1] null for api_key/none and non-expired oauth; tag only for expired oauth
- [ ] `runtime.zig::parseSyslogTransport` — [unit/P1] null for non-`udp`/`tcp`/`tls` *(table-driven)*
- [ ] `runtime.zig::MissingProviderStream` — [unit/P1] yields err event(msg) → stop → null in order
- [ ] `runtime.zig::PrintSink.push` — [unit/P1] inserts newline before error when `text_seen && !text_ended_nl`
- [ ] `runtime.zig::TuiSink.pushSanitized` — [unit/P1] sanitizes id/name/args separately; all three freed on error
- [ ] `runtime.zig::InputWatcher.canceled` — [unit/P1] atomic visibility between watchFn and main on ESC
- [ ] `update.zig::parseVersion` — [unit/P1] extracts version from releases JSON; malformed/missing field handled
- [ ] `update.zig` thread spawn — [unit/P1] OOM/resource-exhaustion on version-check thread spawn handled gracefully
- [ ] `report.zig::Report.append` — [unit/P1] silently truncates event larger than ring capacity

### app/print + modes/rpc

**P0**
- [ ] `tools/builtin.runWeb` redaction *(tracked under core/tools P0; cross-listed)*
- [ ] `rpc.zig::ProcTransport.init` protected path — [unit/P0] rejects `cmd` touching protected paths (`/etc/passwd`, `~/.ssh/`) → `error.InvalidCommand`
- [ ] `rpc.zig::ProcTransport.roundTrip` env scrub — [unit/P0] calls `sandbox.scrubEnv`, removing `PAGER`/`EDITOR`/`SSH_ASKPASS`/secrets before spawning plugin

**P1** — print
- [ ] `print/errors.zig::mapErr` — [unit/P1] all 6 error types → exit codes 10–15 with messages
- [ ] `print/errors.zig::mapResult` — [unit/P1] all 5 StopReason → exit codes null/16–19 with messages
- [ ] `print/format.zig::usageLessThan` — [unit/P1] keeps highest usage (tot>out>in); updates on higher rank
- [ ] `print/format.zig::pushStop` — [unit/P1] keeps highest-rank StopReason (done<tool<max_out<canceled<err)
- [ ] `print/format.zig::sanitizeOutput` OSC — [unit/P1] truncated `ESC ]` at EOF: no overrun/panic
- [ ] `print/format.zig::sanitizeOutput` CSI — [unit/P1] truncated `ESC [ …` at EOF: no panic/loop
- [ ] `print/run.zig::mapEvent` — [unit/P1] all 7 Event variants + fields mapped correctly
- [ ] `print/run.zig::execVerbose` — [unit/P1] `provider.start` err → `error.ProviderStart` (not leaked)
- [ ] `print/run.zig::execVerbose` — [unit/P1] `push` err → `error.OutputFormat`; `finish` err → `error.OutputFlush`
- [ ] `print/run.zig::execVerbose` — [unit/P1] StopReason merged via `merge()`; non-`done` returns error result

**P1** — rpc
- [ ] `rpc.zig::parseResult` — [unit/P1] rejects empty/whitespace, non-object, missing/non-string `jsonrpc`, missing/non-string `id`, missing both error+result → `error.BadResponse`
- [ ] `rpc.zig::dispatch` cancel — [unit/P1] checks cancel before transport (no side effects) AND after transport before parse
- [ ] `rpc.zig::ProcTransport.init` — [unit/P1] rejects empty cmd (`InvalidCommand`) and `max_resp=0` (`InvalidChunkSize`)
- [ ] `rpc.zig::ProcTransport.roundTrip` — [unit/P1] writes full request, closes stdin, reads to EOF; respects `max_resp`; `error.BadExit` on non-zero; `error.Closed` on null pipes
- [ ] `rpc.zig::ProcTransport.roundTrip` pgid — [unit/P1] sets `pgid=0` (non-Windows/WASI) so group is signalable
- [ ] `rpc.zig::ProcTransport.roundTrip` errdefer — [functional/P1] `killAndWait` in errdefer when read fails (no zombie)
- [ ] `rpc.zig::killAndWait` — [unit/P1] SIGTERM to `-pid`, poll ~150ms, escalate SIGKILL; retries on EINTR; ECHILD = success

**P2**
- [ ] `print/format.zig::pushText` — [unit/P2] empty text → `text_seen=false`; no-newline text → `text_ended_nl=false`, finish adds newline
- [ ] `print/format.zig::cmp3`/`lessToolResult`/`hasMeta`/`writeQuoted`/`hexNibble` — [unit/P2] lexicographic order, diag inclusion, control-char escaping, nibble table
- [ ] `print/run.zig::execVerbose` verbose flag — [unit/P2] `verbose=false` → finish emits only errors
- [ ] `rpc.zig::buildCall` — [unit/P2] exact JSON-RPC 2.0 with newline, no extra fields
- [ ] `rpc.zig::parseResult` precedence — [unit/P2] prefers error over result when both present
- [ ] `rpc.zig::dispatch` null cancel — [unit/P2] null cancel pointer safe
- [ ] `rpc.zig::ProcTransport.init` — [unit/P2] dupes cmd (no caller-lifetime dependency); dupes cwd if present
- [ ] `rpc.zig::killAndWait` — [unit/P2] best-effort: swallows `kill()` errors, still calls final `child.wait()`

### modes/tui-a — cmdpicker / input / keybindings / harness / frame / panels

**P0**
- [ ] `cmdpicker.zig::Picker.updateSet` — [unit/P0] `cmds.len + custom.len > 255` falls back builtin-only, `custom=null`, no crash (exact 256 boundary)
- [ ] `cmdpicker.zig::Picker.cmdAt` — [unit/P0] custom index bounds: `idx >= cmds.len` → `ci < custom.len`; debug.assert fires in debug build
- [ ] `cmdpicker.zig::selectedCustom` — [unit/P0] `sel >= n` → null, not panic
- [ ] `keybindings.zig::load` — [unit/P0] overlong home → `BadShape` (not silently-empty bindings)
- [ ] `frame.zig::Frame.init` overflow — [unit/P0] `w*h` overflow (`w=usize.max,h=2`) → `InvalidSize` via checked `mul`

**P1** (selected)
- [ ] `cmdpicker.zig::discoverCustom` — [unit/P1] invalid UTF-8 `COMMAND.md` skipped, not added
- [ ] `cmdpicker.zig::Picker.up/down` — [unit/P1] `n=1` wraps `0→0` no-op
- [ ] `cmdpicker.zig::Picker.fixScroll` — [unit/P1] `n=6,max_vis=5` centering: sel=0→0, sel=5→1, sel=3→0, no under/overflow
- [ ] `cmdpicker.zig::renderDown` — [unit/P1] `w<6` returns early, no `frm.set` panic
- [ ] `input.zig::Reader.next` paste EOF — [functional/P1] EOF during paste returns accumulated `paste_buf[0..paste_len]`
- [ ] `input.zig::Reader.parseOne` — [unit/P1] invalid UTF-8 (isolated continuation `0x80`) advances pos, emits `.none`
- [ ] `input.zig::Reader.remap` null — [unit/P1] identity for `.key/.mouse/.paste/.notify`
- [ ] `input.zig::Reader.readReady` — [functional/P1] poll timeout → `WouldBlock` → `next()` `.none`, not `.err`
- [ ] `input.zig::Reader.compact` — [unit/P1] overlapping `copyForwards` (pos=100,len=256) no corruption
- [ ] `input.zig::Reader.inject` — [functional/P1] injected data parsed without `readReady` (no block)
- [ ] `input.zig::Reader` dual notify — [functional/P1] both notify fds ready → both drain, no loss
- [ ] `keybindings.zig::parse` dup — [unit/P1] semantic duplicate keys → first wins, conflict.name is second spec
- [ ] `keybindings.zig::Bindings.apply` — [unit/P1] unmatched key returned unchanged (`.enter/.tab/char z`)
- [ ] `harness.zig::Ui.updatePreview` — [functional/P1] slash vs @-mention mode exclusive (flip condition mutation caught)
- [ ] `harness.zig::Ui.updatePathCompletion` — [functional/P1] filter to zero clears cache; longer pattern re-scans
- [ ] `harness.zig::Ui.wrapInfo` — [unit/P1] `byte_pos == text.len` computes cur_row/col correctly
- [ ] `harness.zig::Ui.wrapRowCol` — [unit/P1] `target_row` beyond text clamps to end, no panic
- [ ] `harness.zig::Ui.nextCpLossy` — [unit/P1] invalid UTF-8 → null, idx advances past bad byte (no infinite loop)
- [ ] `frame.zig::Frame.init` zero — [unit/P1] `w=0`/`h=0` → `InvalidSize`
- [ ] `frame.zig::Frame.write` — [unit/P1] invalid UTF-8 → `InvalidUtf8`; wide char with 1 col left → break, not overwrite
- [ ] `frame.zig::Layout.compute` — [unit/P1] `panel_h > available` drops panel, transcript fills space
- [ ] `panels.zig::calcCost` — [unit/P1] saturating `*|` clamps at u64.max; cost monotonic (regression vs `*`)
- [ ] `panels.zig::upsertCall` dup ID — [functional/P1] updates name in place, old freed, new duped, moved to tail
- [ ] `panels.zig::moveTail` — [unit/P1] `idx == n-1` returns early, no zero-length memcpy corruption
- [ ] `panels.zig::renderFooter` — [unit/P1] `rect.w=0` returns early, no underflow
- [ ] `panels.zig::PanelRegistry.discover` — [functional/P1] non-OOM read error on one panel skips it, not fatal

**P2**
- [ ] `keybindings.zig::parseKey` — [unit/P2] `char:0` parses distinct from uninit; `char:1114111` ok, `1114112` fails (Unicode max boundary)
- [ ] `input.zig::Reader.drainNotify` — [unit/P2] `n < scratch.len` assumes done, no infinite loop on 1-byte reads
- [ ] `harness.zig::Ui.onKey` — [unit/P2] empty text + submit does not append to transcript
- [ ] `panels.zig::fmtCost` — [unit/P2] `fmtCost(buf,0)` → `"0.000"`
- [ ] `panels.zig::PanelRegistry.addFromMarkdown` — [unit/P2] empty body after trim renders without `splitScalar` panic

### modes/tui-b — overlay / image / color_detect / fuzzy / vscreen

**P0**
- [ ] `overlay.zig::SessionTree.walk` — [unit/P0] cycle (parent→descendant) and >256 nodes: `visited[256]` prevents infinite loop / overflow
- [ ] `overlay.zig::SessionTree.depthOf` — [unit/P0] guard breaks at `guard > nodes.len`, returns clamped depth on broken parent chain

**P1**
- [ ] `overlay.zig::Overlay.selected` — [unit/P1] empty `itemCount` → null even when `sel=0`
- [ ] `overlay.zig::Overlay.fixScroll` — [unit/P1] `max_vis=12` clamps: scroll never > `items.len - max_vis`, never negative
- [ ] `overlay.zig::Overlay.render` — [unit/P1] `box_w < 8` or `box_h > frm.h` returns early, no panic
- [ ] `overlay.zig::SessionTree.isLastSibling` — [unit/P1] only-child / first-of-2 / last-of-3 glyph correctness
- [ ] `overlay.zig::shortLabel` — [unit/P1] model id < 9 chars or non-8-digit suffix returned unchanged, no panic
- [ ] `overlay.zig::writeEllipsis` — [unit/P1] `cols <= 3` with overflow fills dots, no panic
- [ ] `overlay.zig::Overlay.toggle/getToggle` — [unit/P1] `idx >= toggles.len` ignored, no UB
- [ ] `image.zig::writeImageAt` — [unit/P1] `.none` protocol returns immediately, no side effects
- [ ] `image.zig::writeKittyFile` — [unit/P1] `bufPrint` overflow caught → `error.Overflow`; base64 path within 512-byte buffer
- [ ] `image.zig::writeItermFile` — [unit/P1] propagates read errors (missing/perm); `>4MB` → `error.Overflow`
- [ ] `image.zig::isImageType` — [unit/P1] case-insensitive `IMAGE/PNG`, `image/jpeg`, `public.IMAGE`; offset boundary
- [ ] `image.zig::queryClipboardTypesMacos` — [unit/P1] osascript non-zero exit, empty output, oversized stdout/stderr, malformed result
- [ ] `image.zig::splitTypes` — [unit/P1] skips blank lines, trims spaces/tabs on messy clipboard output
- [ ] `color_detect.zig::rgbTo256` boundary — [unit/P1] cube vs grayscale near `(128,128,130)` picks correct ramp
- [ ] `color_detect.zig::rgbTo256` clamp — [unit/P1] avg<4→gi=0(232); avg>243→gi=23(255); test `(2,2,2)`,`(245,245,245)`
- [ ] `color_detect.zig::writeColor` — [unit/P1] idx 16/232/240 downgrades to basic ANSI 0–7 via RGB path, no crash
- [ ] `color_detect.zig::detectTermBg` — [unit/P1] bg index > 15 → null; `COLORFGBG='15;-1'`/non-ASCII → null
- [ ] `fuzzy.zig::score` UTF-8 — [unit/P1] emoji/CJK in query+text: no byte-boundary crash/misalign
- [ ] `fuzzy.zig::score` consec — [unit/P1] `score('aaa','aaa')` absolute value matches formula (`s -= consec*5`)
- [ ] `fuzzy.zig::score` gap — [unit/P1] gap penalty `*2` counts intermediate bytes (`'ac'` vs `'axbc'`)
- [ ] `fuzzy.zig::score` position — [unit/P1] `divTrunc` penalty at positions 9/10/19/20 (no rounding surprise)
- [ ] `vscreen.zig::feed` split UTF-8 — [unit/P1] 2/3/4-byte sequence split across feeds completes correctly (pending buffer)
- [ ] `vscreen.zig::parseEsc` incomplete — [unit/P1] `ESC`, `ESC[`, `ESC[3`, param overflow (`[16]u16`) return incomplete, merge & continue
- [ ] `vscreen.zig::applySgr` — [unit/P1] boundary indices (29/38/39/47/48/89/98/99) ignored, no panic
- [ ] `vscreen.zig::parseEsc` CUP — [unit/P1] `[0;0H`→(0,0); `[9999;9999H`→clamp (h-1,w-1); missing fields default
- [ ] `vscreen.zig::applySgr` truecolor — [unit/P1] `38;2;255;128` (missing blue) → default; `38;2;255;128;64` → `0xff8040`
- [ ] `vscreen.zig::rowText` — [unit/P1] `row >= h` → empty; wide char at end not truncated to padding
- [ ] `vscreen.zig::feed` DEC private — [unit/P1] `[?25h`/`[?25l`/`[?1049h` ignored, text after renders
- [ ] `vscreen.zig::feed` wide boundary — [unit/P1] 2-cell char at `w-1` clamped (not written); at `w-2` fills `w-2`,`w-1`
- [ ] `vscreen.zig::expectFg/expectBg/expectBold` — [unit/P1] return `error.TestExpectedEqual` on mismatch (assert loudly, no silent return)

**P2**
- [ ] *(none beyond P1; `fuzzy.zig` and `color_detect.zig` get fuzz/property targets — see infra)*

### perf + test-infra — src/perf/*, src/test/*

**P0**
- [ ] `audit_e2e.zig::shipAuditRowsWithTracker` — [unit/P0] `error.InvalidAuditChain` propagated on seq_tracker MAC failure (audit integrity boundary)

**P1**
- [ ] `http_mock.zig::Server.init` — [unit/P1] `steps.len == 0` and `> 16` → `error.InvalidResponseCount`
- [ ] `http_mock.zig::Server.initSeq` — [unit/P1] same bounds as `init`
- [ ] `http_mock.zig::readRequest` — [unit/P1] malformed Content-Length → `error.InvalidContentLength`
- [ ] `http_mock.zig::Server.run` — [functional/P1] `matchesExpect` fail sets `failure = error.UnexpectedRequest`
- [ ] `provider_mock.zig::ScriptedProvider.init` — [unit/P1] propagates `pipe()` failure (EMFILE)
- [ ] `provider_mock.zig::ScriptedProvider.init` — [unit/P1] `setCloexec`/`setNonblock` failure cleans pipe (errdefer) and propagates
- [ ] `provider_mock.zig::streamNextImpl` `.block` — [unit/P1] handles poll error and WouldBlock from non-blocking fd
- [ ] `syslog_mock.zig::UdpCollector.spawnCount` — [unit/P1] `n==0` and `n>16` → `error.InvalidCount`
- [ ] `syslog_mock.zig::TcpCollector.spawnCount` — [unit/P1] validates `0 < n <= 16`
- [ ] `syslog_mock.zig::readOctetFrame` — [unit/P1] `InvalidFrame` (no digits / non-digit first byte) and `FrameTooLarge` (`len_used>=32`, `frame_len>buf.len`)
- [ ] `syslog_mock.zig::readFd` — [unit/P1] `BADF` → `error.FileDescriptorClosed`
- [ ] `audit_e2e.zig::extractSyslogMsg` — [unit/P1] `error.InvalidFrame` when `] {` marker missing
- [ ] `ansi_ast.zig::parseCsi` — [unit/P1] truncated CSI (buffer ends before final byte) no crash
- [ ] `ansi_ast.zig::parseOsc` — [unit/P1] truncated OSC (no BEL/ST) no state corruption
- [ ] `tui_ast.zig::extract` — [unit/P1] no border rows → `tx_end` defaults to height
- [ ] `pty_harness.zig::runProc` — [unit/P1] exec failure (nonexistent binary) → non-zero/err
- [ ] `pty_harness.zig::readPipeAlloc` — [unit/P1] respects `limit`, no unbounded alloc (DoS)
- [ ] `pty_harness.zig::mapWaitStatus` — [unit/P1] classifies WIFEXITED/WIFSIGNALED/WIFSTOPPED + signal number
- [ ] `perf/baseline.zig` gate — [mutation/P1] flipping `parse_gate_ns` 10s→100s must FAIL (gate not too loose)
- [ ] `perf/fuzz.zig` policy — [mutation/P1] short-circuit `evaluate()`→`.allow` must FAIL (`deny_ct > 0`)
- [ ] `perf/fuzz.zig` parser — [mutation/P1] assert `errors_seen > 0` when feeding malformed data; removing catch surfaces

**P2**
- [ ] `http_mock.zig::requestLine/header` — [unit/P2] null on truncated/missing CRLF, no panic
- [ ] `syslog_mock.zig::readFd` — [unit/P2] distinguishes EAGAIN vs EINTR vs fatal (no busy-loop)
- [ ] `ansi_ast.zig::summaryAlloc` — [unit/P2] empty ops → empty string
- [ ] `tui_ast.zig::classifyBlock`/`extractModel` — [unit/P2] unknown prefix → `.assistant`; all-space row → null

---

## Phased rollout

Counts are approximate test bodies (some checklist rows fold into one parametrized/table-driven test).

### Phase A — security, correctness, data-loss, and every known-bug regression guard (~75 tests)

All **P0** rows across every area (55), plus the **regression** contracts that lock known bugs:
- Providers: MP2-R1 (EOF after tool_calls without usage), MP3-R1 (provider-scoped auth isolation).
- Session: `decodeSlice` version-range, `ReplayReader.next` UAF (the `P0-1` comment), `atomicExportStream` symlink, `validateSid` NUL.
- Core: `ctEql` constant-time, `Stub.recv` sequence monotonicity, `KeyRing.resolveAt` expiry/revocation, `deniedByPolicy` fail-closed, `validateLeaf` traversal.
- App: policy-lock `system_prompt`, `validateHome`, all `Manager` audit-on-deny paths, `Manager.deinit` cleanup, `PolicyToolDispatch`/`PolicyToolAuth` enforcement, `InputWatcher` overrun.
- Tools/rpc: `runWeb` secret redaction, `ProcTransport.init` protected-path, `roundTrip` env scrub.
- TUI: `cmdpicker` 256-overflow, `SessionTree.walk`/`depthOf` cycle safety, `Frame.init` overflow, `keybindings.load` BadShape.
- Perf/infra: `shipAuditRowsWithTracker` `InvalidAuditChain`.

Ship with the **policy-boundary fixture**, **audit-event assertion helper**, and **TOCTOU injector** so these tests are not bespoke.

### Phase B — P1 functional + e2e journeys (~280 tests)

All **P1** rows. Land the e2e journeys with the existing/extended harnesses:
- `core/providers` e2e: auth env→file resolution, 429 backoff timing, random-chunk SSE reassembly, full Router dispatch (`gpt-5:openai`→OpenAI).
- UX rows get BOTH mock-terminal and PTY layers (`src/test/pty_harness.zig`) per `CLAUDE.md`.
- Build the **OOM allocator**, **mock-PTY queue**, **frame-snapshot helper**, and **error-injection harness** here.

### Phase C — P2 + mutation hardening + coverage/fuzz infra (~85 tests + infra)

- All **P2** rows (44).
- All **mutation** entries (17) recorded in `docs/MUTATION-KILLS.md`, each verified to fail under its named mutation.
- Wire the `fuzz` step + the fuzz targets (glob, stream_parse, fuzzy, plugin parse, sanitizers, export path corpus, color_detect property).
- Wire the `coverage` step (kcov) and run it to find residual uncovered lines.

**Rough totals:** Phase A ≈ 75 · Phase B ≈ 280 · Phase C ≈ 85 → **~440 new meaningful tests** (some rows merge), taking the suite from 1783 toward full meaningful coverage.

---

## How we measure done

1. **kcov line + branch coverage.** Target: **100% of meaningful lines** in `src/` after Phases A+B. Every uncovered line is either (a) a missing test → file a row here, or (b) a comptime-only / unreachable-by-construction line annotated `// coverage: comptime-only` with a one-line justification. Branch coverage gets the same treatment — uncovered branches on guards are bugs in the test, not the code.
2. **Mutation-kill checklist.** Every `category: mutation` row in this doc must be in `docs/MUTATION-KILLS.md` with: the exact mutation (file:line, change), the killing test name, and a confirmed FAIL-on-mutation result. A surviving mutation blocks the row from being checked off — strengthen the test first. This is our substitute for an automated mutator (Zig has none off-the-shelf).
3. **Every PR adds or strengthens a test.** Per `CLAUDE.md`: every bug fix adds or strengthens a test; no PR merges that lowers coverage or leaves a touched guard untested. The Per-Dot Verification Gate names the specific test exercising each acceptance criterion.
4. **`zig build test` and `zig build perf` stay green; `zig build fuzz` runs the targets; `zig build coverage` reports the numbers.** Snapshots via `ohsnap` for structs; `expectEqual` only for scalars.
