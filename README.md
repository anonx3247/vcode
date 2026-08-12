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
vc session attach <id> [--move-session]
vc --rpc
```

The interactive UI provides `/model [provider:model]`, `/skill [skill-name]`, `/resume`, `/goal`, and `/review`. `/model`, `/skill`, and `/resume` use `fzf`; ordinary CLI lists stay plain and pipe-friendly. Skills are discovered at startup but their contents are read only after an explicit `/skill` command.

Example configuration:

```toml
default_model = "openai:gpt-5.2"
effort = "medium"
small_model = "openai:gpt-5-mini"

[providers.openai]
kind = "openai"
base_url = "https://api.openai.com/v1"
```

API keys can be set in provider configuration or supplied as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `BRAVE_API_KEY` environment variables.

## Development

Run `scripts/bootstrap-v.sh` to install the pinned compiler under `.tmp/v`, then use `make check`. `scripts/bench.sh` reports warm-start latency and peak RSS.

