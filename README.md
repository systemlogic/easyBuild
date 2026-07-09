# easy_build: hermetic multi-language Bazel workspace

This workspace is scaffolded by `easy_build init --language=<cpp|java|python>`.
Every configured language shares one `MODULE.bazel` and one `.bazelrc`
(each language owns a marked `EASY_BUILD:BEGIN/END` block in both), and
gets its own sample program under `example/<language>/`. Running `init`
for a new language adds its block/example rather than replacing an
existing language's.

## Configured languages

- **cpp** (v20.1.7) -- `example/cpp/README.md`, `bazel run //example/cpp:hello`
- **java** (v21) -- `example/java/README.md`, `bazel run //example/java:hello`
- **python** (v3.12) -- `example/python/README.md`, `bazel run //example/python:hello`

Default target platform for this host: `macos_aarch64`

## Files

- `MODULE.bazel` / `.bazelrc` -- shared toolchain registration and
  flags, one marked block per configured language.
- `platforms/BUILD.bazel` -- the four target `platform()` definitions.
- `example/<language>/` -- that language's sample program, `BUILD.bazel`,
  and its own `README.md` with language-specific usage/verification steps.
