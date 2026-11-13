# Contributing to nengine

Thanks for helping. A few rules keep the engine what it is:

- **Odin only, no third-party libraries.** Odin's `core:` and `vendor:raylib`, nothing else.
- **Mechanism, not content.** The engine serves many games, so nothing in it names a
  particular game's people, places or story. If a feature can only be described by
  telling one game's plot, it belongs in that game. See "What belongs in here" in
  [README.md](README.md).
- **Asset files are the truth.** Art, music and rooms live in their text formats and
  are edited with the tools in `tools/`; code never paints art.
- **Tests pass before review.** Run `odin check nengine -no-entry-point -vet` and
  `odin test nengine`, plus the packages under `tools/` that you touched. Set
  `NENGINE_HIDDEN=1` while testing so no window opens.

Open an issue before a large change so we can agree the shape first. Security
problems go through [SECURITY.md](SECURITY.md), never a public issue.

By contributing you agree your contribution is licensed under the
[MIT licence](LICENSE) that covers the project.
