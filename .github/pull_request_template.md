# Proposed changes

What this changes, and why.

## Linked issue

`Refs #123` or `Fixes #123`, or `N/A`.

## Checklist

- [ ] `odin check nengine -no-entry-point -vet` is clean.
- [ ] `odin test nengine` passes (and the tool packages under `tools/` that this touches).
- [ ] No third-party libraries: only Odin's `core:` and `vendor:raylib`.
- [ ] Mechanism, not content: nothing here names a particular game's people, places or story.
- [ ] Docs updated (`README.md`, `tools/README.md`) if behaviour changed.

## Security

What input is untrusted (asset files, save files, typed commands), and what could a bad file do?
