# Adding a Provider to `pz`

`pz` ships native clients for Anthropic and OpenAI plus a set of OpenAI-compatible
providers (OpenRouter, Google, Mistral, Groq, DeepSeek). This guide is the
end-to-end checklist for wiring in a new provider. Every step is a hard cutover —
no fallbacks, no silent defaults; an unresolved provider is a named error.

## Surfaces you touch

| File | What you add |
| --- | --- |
| `src/core/providers/<name>.zig` | The provider module (a `Cfg` + `Client`). |
| `src/core/providers/registry.zig` | `ProviderTag` variant + `ProviderInfo` row. |
| `src/core/providers/models.zig` | One `ModelInfo` row per known model. |
| `src/core/providers.zig` | `pub const <name> = @import("providers/<name>.zig");` |
| `src/app/runtime.zig` | Kind enum + env map entry (so `pz login <name>` resolves). |
| `src/tests.zig` | Register the new module's tests. |

## 1. The provider module

Most providers speak the OpenAI Chat-Completions wire format. For those, reuse the
`ChatCfg` builder (see `openrouter.zig`) — you only declare host/path/key, never
re-implement SSE parsing or body building:

```zig
// src/core/providers/acme.zig
const openrouter = @import("openrouter.zig");
const hc = @import("http_client.zig");

pub const Cfg = openrouter.ChatCfg(.{
    .api_host = "api.acme.ai",
    .api_path = "/v1/chat/completions",
    .key_env = "ACME_API_KEY",
});
pub const Client = hc.SseClient(Cfg);
```

A provider with a bespoke wire format (like Anthropic's `/v1/messages`) implements
its own `Cfg.buildBody` / stream parser instead of borrowing `ChatCfg`. Mirror
`anthropic.zig` in that case.

Add unit tests in the module: at minimum `buildBody` produces the expected JSON
and `buildAuthHeaders` emits the right `Authorization`. Use `expectEqualStrings`
for raw wire bytes; `ohsnap` for multi-field structs.

## 2. Registry entry

Add a `ProviderTag` variant and a `ProviderInfo` row in `registry.zig`:

```zig
pub const ProviderTag = enum { anthropic, openai, openrouter, google, mistral, groq, deepseek, acme };

// in the providers table:
.{
    .tag = .acme,
    .api_host = "api.acme.ai",
    .api_path = "/v1/chat/completions",
    .auth_type = .api_key,          // or .oauth
    .base_url_env = "ACME_BASE_URL", // host/path override read at request-build time
}
```

`auth_type` is `.api_key` for key-based providers and `.oauth` for subscription /
device-flow providers (Anthropic, OpenAI). `resolveProvider` is a pure,
allocation-free lookup — keep the table comptime-known.

## 3. Model rows

Add one `ModelInfo` per model in `models.zig`'s `registry`:

```zig
.{ .name = "acme-large", .provider = .acme, .ctx_win = 128_000, .in_cost = 300, .out_cost = 900, .cache_read = 30, .cache_write = 0, .thinking = false, .rate_limit_tpm = 200_000 },
```

Costs are micro-cents per million tokens. Lookup is longest-exact-prefix and
**provider-scoped** (MP3-R1) — there is no substring fallback, so a bare name and a
`provider/`-prefixed name resolve to distinct rows. Users can override or extend
the registry at runtime via `~/.pz/models.json` (MP6) — file entries win over the
static table; malformed config is a surfaced error, never a silent default.

## 4. Export + runtime wiring

```zig
// src/core/providers.zig
pub const acme = @import("providers/acme.zig");
```

In `runtime.zig`, add the provider to the kind enum and the env/CLI map so
`pz login acme` resolves to the api-key path:

```zig
// native_provider_kind_map / provider env map
.{ "acme", .acme },
```

For an OpenAI-compatible provider this routes through the **dynamic provider arm**
(the comptime-erased `Router` from `client.zig`); Anthropic/OpenAI keep their
native fast-path union arms. Every `switch` over the provider union must stay
exhaustive — no `unreachable`, no missing arm.

## 5. End-to-end test

Add a mock stream test proving the provider streams through the runtime, mirroring
the existing per-provider `testStream`/`testParse` helpers. The full suite
(`zig build test`) must stay green with zero leaks.

## Examples

- **OpenRouter** — aggregator; `api.openrouter.ai`, `/api/v1/chat/completions`,
  `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`. Model names are `provider/model`
  slugs, which is why provider-scoped lookup matters.
- **Google (Gemini)** — OpenAI-compatible endpoint; key via `GOOGLE_API_KEY`.
- **Azure OpenAI** — same OpenAI wire format but a per-deployment host/path:
  set `.base_url_env = "AZURE_OPENAI_BASE_URL"` and point it at your deployment
  URL; the key flows through the api-key auth path.

## Error paths & precedence

1. **Auth resolution** — env var (`<NAME>_API_KEY` / OAuth token) → `~/.pz/auth.json`
   file entry. A provider with no resolvable credential returns
   `error.AuthNotFound`; it is never silently skipped.
2. **Model config** — `~/.pz/models.json` overrides the static registry by name;
   wildcards (`provider/*`) apply to matching names; a malformed file or invalid
   `ctx_win`/cost surfaces `error.BadModelConfig`.
3. **Provider dispatch** — explicit `Request.provider`, else the `:provider` suffix
   on the model id, else the model's registry `provider`. An unknown provider is a
   named error before any request is built — no fallback to a default provider.
