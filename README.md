# wedepend
A DLang dependency tracker, it knows to ignore unittest and version blocks and can help interface into an external build system.

## Building

Native build (auto-detects the host OS/arch via `uname`):

    make

Cross-compile for another target triple by overriding `TRIPLE`:

    make TRIPLE=aarch64-linux-gnu
    make TRIPLE=x86_64-linux-gnu
    make TRIPLE=x86_64-apple-darwin
    make TRIPLE=arm64-apple-darwin

`make test` only works for a native build (`TRIPLE` unset or matching the
host); it refuses to run for a cross target since the resulting binary can't
execute on this host.

### Cross-compilation prerequisites

Passing `TRIPLE=` only sets `ldc2`'s `-mtriple`; it does not by itself
produce a working cross-linked binary. You'll also need, for the target
triple:

1. A druntime/phobos2 built for that triple (e.g. via `ldc-build-runtime`),
   wired in through a custom `ldc2.conf` with a triple-matched section,
   passed via `LDC_CONF=/path/to/ldc2.conf`.
2. A linker/toolchain capable of producing the target's binary format, e.g.
   `lld` with an appropriate sysroot, or a wrapper such as `zig cc`. Wire
   these in with `LINKER=`, `GCC=`, and/or `SYSROOT_FLAGS=`, e.g.:

       make TRIPLE=aarch64-linux-gnu \
            LDC_CONF=$HOME/.ldc/aarch64-linux-gnu.conf \
            LINKER=lld \
            SYSROOT_FLAGS='-L--sysroot=/path/to/sysroot'

See LDC's cross-compilation documentation for building target runtimes and
sysroots; this Makefile only provides the override hooks, not the toolchain.
