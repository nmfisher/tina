# Console diagnostics

These tools exercise the same native input/rendering code as the console.
Run `dart pub get` in `packages/tina_console` first. From the repository root:

```sh
python3 packages/tina_console/tool/altkey_pty_driver.py
```

That driver is a CI regression check for text, modifiers, repeats, releases,
terminal replies and the fallback PTY path. It needs no physical terminal.
`mute_pty_driver.py` and `stop_hang_driver.py` isolate related startup/shutdown
cases; `altkey_probe.dart` and `nc_key_dump.dart` support manual key inspection.

The ticket-named tools are retained as targeted rendering reproducers:

- `p8k2_repro.dart` and `p8k2_check.dart` reproduce and check panel-border damage
  by replaying captured terminal output through the console test emulator.
- `q4vz_harness.dart` traces rendering operations while feeding a paste corpus.
- `resize_probe.dart` inspects native child-plane resize positioning.
- `reply_decode_spike.dart` logs decoding of injected terminal replies.

The old tmux shell drivers assume the original `/workspace` Linux repro
container. The Dart probes can also be launched directly from this package.
They are package-local diagnostics and need no cross-package import exceptions.
