# vcode

`vcode` is a compact, memory-bounded coding agent written for V 0.5.2. Its executable is `vc`.

```sh
make build
./vc 'explain this repository'
./vc --rpc
```

Configuration lives at `~/.config/vc/config.toml`. Session journals are append-only JSONL files under `~/.local/state/vc/sessions`.

## Commands

```text
vc [options] <prompt>
vc model list
vc model set <provider:model> [--effort <level>]
vc session list
vc resume <id> [--move-session]
vc session attach <id>
vc --rpc
```

The interactive UI provides `/model [provider:model]`, `/skill [skill-name]`, `/resume`, `/goal`, and `/review`. `/model`, `/skill`, and `/resume` use `fzf`; ordinary CLI lists stay plain and pipe-friendly. Skills are discovered at startup but their contents are read only after an explicit `/skill` command.
`/review <instructions>` starts a fresh read-only tool-using agent, clearly marks its start and finish, and adds only its final findings to the main session context.
Running `vc` without a prompt starts a new interactive session. If its configured default provider is unavailable, it opens the model picker before creating the session.
Each turn replays a bounded projection of the session's user, assistant, system, and tool history. The full transcript remains in the append-only journal. Session recaps are generated after the first completed turn and refreshed after ten active minutes; `/resume` shows the recap first.
`vc resume <id>` reopens the conversational TUI and prints its recap before the prompt. `vc session attach <id>` only attaches to the persistent worker for live RPC use.

Example configuration:

```toml
default_model = "openai:gpt-5.2"
effort = "medium"
small_model = "openai:gpt-5-mini"

[providers.openai]
kind = "openai"
base_url = "https://api.openai.com/v1"

[providers.isara]
kind = "openai"
base_url_env = "OPENAI_BASE_URL"
api_key_env = "OPENAI_API_KEY"
```

API keys can be set in provider configuration or supplied as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `BRAVE_API_KEY` environment variables.
`vc model list` queries only providers declared in this file, caches successful results for 15 minutes, and reports discovery failures instead of inventing fallback models.

The `Read` tool accepts optional 1-based inclusive `start` and `end` line numbers. Without a range it returns at most the first 3000 lines, additionally bounded by the tool's byte limit.

## Development

Run `scripts/bootstrap-v.sh` to install the pinned compiler under `.tmp/v`, then use `make check`. `scripts/bench.sh` reports warm-start latency and peak RSS.
