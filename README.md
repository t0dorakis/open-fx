# fx-codex

A fork of [vercel-labs/fx](https://github.com/vercel-labs/fx) that runs the agent on a
**ChatGPT/Codex subscription** instead of the Vercel AI Gateway.

Everything else is upstream fx. The Codex support is additive: a new `src/codex/` provider plus
small edits to five upstream files, so the fork stays cheap to rebase onto new fx releases.

## Read this first

This signs in with the OAuth client the Codex CLI uses and calls the Codex backend from a different
program. That is **not an OpenAI-sanctioned integration path**, and the consequences land on your
account, not on this repository:

- OpenAI can rate-limit, block, or ban accounts for out-of-client use. Nobody here can appeal that
  for you.
- The client id and backend contract are not a published API. They can change or be revoked without
  notice, and when they do this fork simply stops working.
- Sign-in binds to port `1455`, the same port the Codex CLI uses, so the two cannot sign in at once.

If that is not a trade you want to make, use upstream fx. It is the better-supported tool.

## Install

Requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/t0dorakis/fx.git fx-codex
cd fx-codex
zig build -Doptimize=ReleaseSafe
```

Prebuilt binaries are attached to [releases](https://github.com/t0dorakis/fx/releases). They are
unsigned, so macOS quarantines them on download:

```bash
xattr -d com.apple.quarantine ./fx
codesign --force --sign - ./fx
```

To put it on `PATH` in place of fx, remove the old binary before copying rather than overwriting it.
Overwriting a running binary's inode invalidates the cached code signature, and macOS then kills it
with `SIGKILL` on the next launch:

```bash
rm -f ~/.local/bin/fx
cp zig-out/bin/fx ~/.local/bin/fx
codesign --force --sign - ~/.local/bin/fx
```

## Use

```bash
fx login --codex     # browser sign-in against auth.openai.com
fx status            # should report: auth=Codex (ChatGPT) login
fx ask "explain this repository"
```

`fx login --codex` also records `credential_source: codex_oauth` in `~/.fx/settings.json`. A Codex
token is not a Gateway credential, so it does not win fx's normal credential precedence and has to
be selected explicitly; the login command does that for you.

Credentials are stored in `~/.fx/codex-auth.json`, mode `0600`. The refresh token rotates on every
use, so refreshes are single-flight and the new credential is written to disk before it is handed
out.

`fx models` lists the live Codex catalog and `fx credits` reports your Codex rate-limit window in
place of a credit balance.

### Switching back

```bash
fx logout --codex
```

That deletes the credential and clears `credential_source`, leaving fx on the Gateway with your
Vercel login intact. Both credentials can coexist; only the setting decides which is used.

## Verified and not verified

Streaming text, tool calls, reasoning replay, the model catalog, rate-limit reporting, browser
sign-in, and token refresh are exercised against captured live transcripts in
`src/codex/testdata/` or against the real backend.

**Vision (image input) and structured output have never been run against Codex.** They are
translated, not tested. Expect to find bugs there first.

## How it works

`src/codex/provider.zig` implements fx's own `gateway_provider.Provider` interface, so the Codex
path is a peer of the Gateway path rather than a proxy in front of it. `src/main.zig` picks between
them at startup from `credential_source`.

The translation layer maps fx's AI SDK call options onto the Codex Responses API
(`chatgpt.com/backend-api/codex/responses`, `store: false`, encrypted reasoning included) and maps
the `response.*` SSE events back to Gateway stream parts.

fx's message history has no slot for provider reasoning, so the chain of thought behind a tool call
would be lost at the end of each turn. `src/codex/runtime.zig` keeps encrypted reasoning keyed by
the tool call it preceded and splices it back into later turns, which keeps the prompt cache warm.
It is bounded at 512 entries.

### Automatic upgrades are disabled

The fork reports its version as `0.0.3-codex.N`, and any build carrying that marker refuses both
background auto-upgrade and `fx upgrade`. Upstream's release feed serves upstream binaries, and
installing one would silently replace this fork with stock fx and remove Codex support. Update by
rebuilding from source.

## Staying current with upstream

```bash
git remote add upstream https://github.com/vercel-labs/fx.git
git fetch upstream
git rebase upstream/main
```

`main` tracks upstream unchanged; the fork lives on `codex-provider`. Conflicts should be limited to
the five files that carry a `Modified from vercel-labs/fx` notice at the top:

| File | Change |
| --- | --- |
| `src/main.zig` | provider selection, fork build identity |
| `src/core/cli/cli_surface.zig` | `login --codex`, `logout --codex`, upgrade refusal |
| `src/core/auth/credentials.zig` | loads and ranks the Codex credential |
| `src/core/auth/auth_runtime.zig` | adds `codex_oauth` to the source order |
| `src/core/shared/types.zig` | adds the `codex_oauth` enum member |

Everything else is under `src/codex/`, which upstream never touches.

CI is not enabled on this fork. Run `zig build test` before pushing.

## Documentation

For fx itself, read the [upstream README](https://github.com/vercel-labs/fx#readme) and the
[fx documentation](https://fx.sh/docs). This fork changes how fx authenticates and which backend it
talks to, nothing else.

## License

[Apache-2.0](LICENSE), inherited from upstream fx. Modified files carry a change notice as the
license requires.

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Interface sounds by
[cuelume](https://github.com/Danilaa1/cuelume).

Not affiliated with Vercel or OpenAI.
