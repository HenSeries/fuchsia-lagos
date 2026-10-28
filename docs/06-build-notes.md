# 06 — Build environment notes & the Bazel sandbox fix

Notes from getting a Fuchsia checkout to build on the host (Arch Linux, kernel 7.2.x,
12 cores, 22 GB RAM, /dev/kvm present).

## Checkout

```bash
cd /home/hen/Documentos/code/android
bash fuchsia-bootstrap.sh 2>&1 | tee fuchsia-lagos/build.log   # official Fuchsia bootstrap
```

- Produces the tree at `/home/hen/Documentos/code/android/fuchsia` (~41 GB after checkout).
- A `cipd` WARN about "packages skipped due to lack of access" is **normal** for non-Googlers
  (internal-only prebuilts). The public build does not need them.

## Configure

```bash
cd fuchsia && export PATH="$PWD/.jiri_root/bin:$PATH"
fx set bringup.x64        # minimal product; same product *type* we'll use for lagos
```

We use `bringup.x64` (not `workstation_eng.x64`) to validate the toolchain: it's the
minimal product, builds much faster, boots in femu, and matches the `bringup` product we
target on `lagos`.

## The Bazel sandbox bug (and fix)

### Symptom

`fx build` fails almost immediately (~100 s, exit 1) with ~50 FAILED actions, all of the
form:

```
FAILED: [code=1] obj/tools/<tool>/<tool>.host.bazel_target_can_only_be_referenced_by_one_bazel_action ...
```

> The long `...bazel_target_can_only_be_referenced_by_one_bazel_action` name is just the
> **stamp output** of a GN `bazel_action` (see `build/bazel/bazel_action.gni`), **not** the
> error. The real failure is the Bazel invocation inside that action returning exit 1.

The underlying Bazel error:

```
Compiling Rust bin _bs_ ... [for tool] failed: (Exit 1): process_wrapper failed:
error executing Rustc command (from target //third_party/rust_crates/vendor/<crate>:_bs_)
... Use --sandbox_debug to see verbose messages from the sandbox ...
```

i.e. Bazel-built **host tools** (netprotocol, zedmon, testgen, power_config, device-finder,
fidl_api_summarize, …) fail while compiling Rust crate *build scripts*. The GN build of
Zircon/C++ is fine; only the GN→Bazel host-tool bridge fails.

### Root cause

Bazel's **`linux-sandbox` breaks `rustc`** on this host. Proof:

```bash
# via the bridge (sandboxed)  -> FAILS (Exit 1, stderr swallowed)
# direct, no sandbox          -> SUCCEEDS
fx bazel build --config=host //third_party/rust_crates/vendor/memoffset-0.9.1:_bs_ \
    --verbose_failures --spawn_strategy=local
#   INFO: Build completed successfully
```

The prebuilt GN `rustc` runs fine standalone (`rustc 1.101.0-nightly`), unprivileged user
namespaces are enabled (`kernel.unprivileged_userns_clone=1`, `unshare --user` works), so
it is specifically the Bazel linux-sandbox environment that `rustc` can't run in. It is
**not** OOM/concurrency: the failure is instant and deterministic even with warm caches.

### Root cause (the real one) and fix

The culprit is **Bazel 8.x sandbox-directory reuse** (`--reuse_sandbox_directories`, on by
default). Reusing a sandbox dir corrupts `Rustc` actions on this host — rustc exits 1 with
no stderr. The tell: the exact action **succeeds with `--sandbox_debug`**, and per Bazel's
docs `--sandbox_debug` *disables sandbox reuse*. Confirmed on a fresh action (after
`fx bazel clean`): sandbox ON + reuse OFF → `Compiling Rust bin runner ... linux-sandbox` →
`Build completed successfully`.

So the fix keeps the sandbox and only disables reuse. Applied in **two** places:

1. `build/bazel/templates/template.bazelrc` — the source template (persists across `fx gen`):
   ```
   build --noreuse_sandbox_directories
   ```
2. The already-generated `out/<build-dir>/gen/build/bazel/workspace/.bazelrc`.

> **Dead ends we ruled out** (don't repeat them):
> - `build --spawn_strategy=local` — fixes rustc but then product assembly fails copying a
>   GN board-input-bundle *directory* (`obj/boards/x64/paver`): *"the source path is
>   neither a regular file nor a symlink to a regular file"*. Unsandboxed, Bazel exposes GN
>   outputs as symlinked dirs the copy tool rejects.
> - `build --strategy=Rustc=local` — does **not** actually reroute these actions; they still
>   run sandboxed and fail. (An x64 build appeared to pass with it only because the rust
>   host tools were already cached from manual runs.)
>
> Keeping the sandbox (reuse off) is what lets both rustc *and* the assembly copy work.

Validated end-to-end on x64 earlier (`fuchsia.zbi` 32 MB); the arm64 build uses the same fix.

> If `fx set`/`fx gen` ever regenerates the workspace rc and the template edit was lost,
> re-apply the one `build --noreuse_sandbox_directories` line.

## Build artifacts (bringup.x64)

| name | path (under build dir) |
|---|---|
| `zircon-a` zbi | `obj/products/bringup/product_bundle.x64/product_bundle/system_a/fuchsia.zbi` |
| kernel zbi | `kernel.eng.zbi` |

## Next

Once `fx build` is green: `ffx emu start` (femu) to boot bringup.x64 and confirm the
toolchain end-to-end, then move to the `lagos` arm64 board config (see
[05-next-steps.md](05-next-steps.md)).
