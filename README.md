# easy_build: hermetic multi-language Bazel workspace

This workspace is scaffolded by `easy_build init --language=<lang>`, where
`<lang>` is one of: cpp, java, python, go, rust, kotlin, scala, haskell.
Every configured language shares one `MODULE.bazel` and one `.bazelrc`
(each language owns a marked `EASY_BUILD:BEGIN/END` block in both), and
gets its own sample program under `example/<language>/`. Running `init`
for a new language adds its block/example rather than replacing an
existing language's.

## Configured languages

- **python** (v3.12) -- `example/python/README.md`, `bazel run //example/python:hello`

Default target platform for this host: `macos_aarch64`

## Linting

`bazel build --config=lint //example/...` runs each configured language's
hermetic lint aspect and fails on any violation:

- **python** -- `ruff`

## Files

- `MODULE.bazel` / `.bazelrc` -- shared toolchain registration and
  flags, one marked block per configured language.
- `platforms/BUILD.bazel` -- the four target `platform()` definitions.
- `tools/lint/` -- lint aspect definitions (`linters.bzl`) and any custom
  linter binary wiring (`BUILD.bazel`), composed across configured languages.
- `example/<language>/` -- that language's sample program, `BUILD.bazel`,
  and its own `README.md` with language-specific usage/verification steps.
