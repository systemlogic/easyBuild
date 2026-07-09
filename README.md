# easy_build: hermetic C++ project (clang/LLVM via Bazel)

This project was scaffolded by `easy_build init --language=cpp`. It builds
entirely with a clang/LLVM toolchain that Bazel downloads itself (via the
`toolchains_llvm` module, pinned to LLVM 20.1.7). Your system compiler
(gcc, Xcode clang, MSVC, ...) is never invoked -- only Bazel and a Python 3
interpreter (used by Bazel's own repository rules) are required on the host.

## Supported target platforms

  - linux_x86_64
  - linux_aarch64
  - macos_x86_64
  - macos_aarch64

Each is a *native* build target: run the matching `--config` on a machine of
that exact OS/arch (e.g. in a CI matrix) and Bazel downloads and uses clang/LLVM
20.1.7 built for that platform -- your system compiler is never invoked.
This mirrors how `toolchains_llvm` itself recommends using it: one hermetic
toolchain per real host, not one machine cross-building all four.

## Usage

```sh
# Uses the default --config for this host (macos_aarch64):
bazel build //:hello
bazel run   //:hello

# Explicitly target a platform (only correct when run on a matching host):
bazel build --config=linux_x86_64  //:hello
bazel build --config=linux_aarch64 //:hello
bazel build --config=macos_x86_64  //:hello
bazel build --config=macos_aarch64 //:hello
```

## Verifying no host compiler is used

```sh
bazel aquery --config=macos_aarch64 'mnemonic("CppCompile", //:hello)' | grep -A1 'Command Line'
```

The executable must be under `external/toolchains_llvm++llvm+llvm_toolchain/...`.
If it ever points at `/usr/bin/clang`, an Xcode path, or
`external/apple_support+/...` / `external/local_config_cc/...`, host tooling is
being used -- stop and investigate before trusting the build.

### A real limitation on macOS: mismatched arch silently uses Xcode

Only the config matching your **current** machine is guaranteed hermetic.
Running `--config=macos_x86_64` on Apple Silicon (or `--config=macos_aarch64`
on an Intel Mac) does **not** fail -- `rules_cc` depends on `apple_support`,
which auto-registers a fallback toolchain backed by the *system* Xcode clang
for whichever Apple arch our hermetic LLVM download doesn't natively cover.
Bazel's toolchain resolution then silently falls through to it. This isn't a
gap in this scaffold's config; `toolchains_llvm` only synthesizes a working
cc_toolchain when the LLVM distribution's exec arch equals the target arch,
and there is no redistributable macOS SDK sysroot to cross that gap hermetically
(Apple's SDK license forbids it) -- so it can't be closed without a real
machine of that arch.

Linux does not have this problem: requesting a mismatched Linux `--config` on
any host fails the build outright (no toolchain found) rather than silently
substituting a host compiler -- verified by running `--config=linux_aarch64`
from an aarch64 macOS host above.

**Practical rule: only build a given `--config` on a real machine of that
OS/arch** (e.g. one CI runner per platform). Use the verification command
above whenever you're unsure.

## Files

- `MODULE.bazel` -- declares the hermetic `toolchains_llvm` toolchain and
  registers it ahead of Bazel's built-in host-autodetected one.
- `platforms/BUILD.bazel` -- the four target `platform()` definitions.
- `.bazelrc` -- one `build:<platform>` config per target, defaulting to
  `macos_aarch64` for this host.
- `BUILD.bazel` / `hello.cpp` -- a sample `cc_binary` that prints its OS,
  arch, and confirms it was compiled with clang.
