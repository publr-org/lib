# Publr Zig

Zig's compiler, carried inside the binary that imports this module, for building
WebAssembly modules on a machine with no Zig installed. The compiler, its standard
library and a prebuilt compiler_rt travel as one compressed archive; `unpack` writes them
to a folder once, and the host runs the compiler from there as a child process.

```zig
const publr_zig = @import("publr_zig");

const toolchain = try publr_zig.unpack(io, arena, "data/toolchain");
const argv = [_][]const u8{
    toolchain.compiler, "build-exe", "plugin.zig", toolchain.compiler_rt,
    "-target", "wasm32-freestanding", "-rdynamic",
} ++ publr_zig.wasm_flags;
```

## The contract

**It builds `wasm32` only.** The compiler is Zig's own, built without LLVM, so it emits
WebAssembly with its own backend and linker, and cannot build for native targets.
`wasm_flags` are the flags a module needs from it: no LLVM, no LLD, no sanitizer runtime,
no entry point run while the module is instantiated, and compiler_rt from the toolchain
(`Toolchain.compiler_rt`, passed as an input) instead of built on the spot, which the
wasm backend cannot do yet.

**Unpacked once, by content.** The folder is named for the archive
(`zig-0.17.0-<hash>`): a binary with another toolchain never uses this one's files.
Unpacking goes to a folder of its own and is renamed into place, so a process stopped
halfway leaves nothing that looks finished, and two processes unpacking at once both end
with the same folder. About 32 MB on disk; the archive in the binary is about 8 MB.

**Vendored, as released.** `vendor/zig/` is Zig 0.17.0's source, the parts its own
`build.zig` needs to configure and build the compiler (`src/`, `lib/std`,
`lib/compiler_rt`, `test/`, `doc/`), unchanged (MIT, `vendor/zig/LICENSE`), from the
release tarball with SHA-256
`b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd`. It is built by
Zig's own `build.zig`, full and without LLVM (`-Dno-lib`). Its wasm-only preset
(`-Ddev=wasm`) is under a third of the size and, since 0.17, has the `legalize` pass the
wasm backend needs; it is not used until installed plugins are checked with it. The build
compiles it once (about two minutes); Zig's cache keeps it.
`zig build toolchain -Dtarget=<target>` writes the archive to `zig-out/`, and
`-Dtoolchain-archive=<file>` uses such an archive instead of building one, so CI builds it
once per target and Zig.

## Tests

```bash
zig build test
```

The integration test unpacks the real toolchain into a temporary folder, twice, and
builds `tests/guest.zig`, which needs compiler_rt, into a module.
