# vcode

`vcode` is a compact coding agent written for V 0.5.2. Its executable is `vc`.

```sh
make build
./vc 'explain this repository'
./vc --rpc
```

Configuration lives at `~/.config/vc/config.toml`. Session journals are append-only JSONL files under `~/.local/state/vc/sessions`.

