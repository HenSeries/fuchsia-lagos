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

### Fix

Disable Bazel sandboxing for this build. Applied in **two** places:

1. `build/bazel/templates/template.bazelrc` — the source template (persists across `fx gen`):
   ```
   build --spawn_strategy=local
   ```
2. The already-generated `out/<build-dir>/gen/build/bazel/workspace/.bazelrc` (so no regen
   needed immediately).

Validated: `fx bazel build --config=host //tools/power_config:power_config` then went from
FAIL → `Build completed successfully, 360 total actions` (all `local`).

> Trade-off: loses sandbox hermeticity. Fine for a local dev/research build. A more
> surgical variant is `build --strategy=Rustc=local` (sandbox everything except Rustc).
> If `fx set`/`fx gen` ever regenerates the workspace rc and the template edit was lost,
> re-apply the one line above.

## Build artifacts (bringup.x64)

| name | path (under build dir) |
|---|---|
| `zircon-a` zbi | `obj/products/bringup/product_bundle.x64/product_bundle/system_a/fuchsia.zbi` |
| kernel zbi | `kernel.eng.zbi` |

## Next

Once `fx build` is green: `ffx emu start` (femu) to boot bringup.x64 and confirm the
toolchain end-to-end, then move to the `lagos` arm64 board config (see
[05-next-steps.md](05-next-steps.md)).
