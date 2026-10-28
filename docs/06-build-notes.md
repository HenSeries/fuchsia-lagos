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

The culprit is **memory exhaustion under Bazel's default concurrency**, not rustc itself.
`fx build` runs ninja at `-j12`, ninja fans out many GN `bazel_action` targets at once, and
each drives sandboxed Bazel compiles. On this host (**22 GB RAM, no swap**) the concurrent
sandboxed rust/C++ actions exhaust memory and the kernel **kills** processes. The symptoms
look like two different bugs but are the same thing:

- `rustc` actions: *"error executing Rustc command (Exit 1)"* with **no stderr** (the
  process was killed before it could print anything), and *"Use --sandbox_debug…"*.
- other actions (e.g. `GenFidlResponseFile`): literally *"(Killed)"*.

> The long `...bazel_target_can_only_be_referenced_by_one_bazel_action` filename is just the
> GN `bazel_action` **stamp output** (`build/bazel/bazel_action.gni`), not the error.

**Proof:** the exact same host-tool set that dies at default concurrency builds cleanly with
`--jobs=4` (1151 actions, all `linux-sandbox`, `exit=0`). Low-concurrency / isolated builds
always worked — which is why `--sandbox_debug` and single-target tests misleadingly
"passed" earlier.

**Fix** — cap Bazel's local concurrency (and, kept from the earlier hypothesis, disable
sandbox reuse). `--jobs` only throttles **Bazel**, not ninja's C++ compiles, so Zircon still
builds at full speed; only the problematic bazel rust host tools are serialized. In
`build/bazel/templates/template.bazelrc` (persists across `fx gen`) and the live workspace rc:

```
build --noreuse_sandbox_directories
build --jobs=4
```

> **Alternative / faster:** add swap (we have >180 GB disk free). With e.g. a 32 GB swapfile
> the `--jobs` cap can be raised or dropped. Needs `sudo`:
> `sudo fallocate -l 32G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`

> **Dead ends we ruled out** (don't repeat):
> - `--spawn_strategy=local` — fixes the kills but then product assembly fails copying a GN
>   board-input-bundle *directory* (`obj/boards/x64/paver`): *"source path is neither a
>   regular file nor a symlink"* (unsandboxed, GN outputs are symlinked dirs the copy tool
>   rejects).
> - `--strategy=Rustc=local` — doesn't reroute the actions; they still run sandboxed. An x64
>   build only appeared to pass with it because the rust host tools were already cached.
>
> Keeping the sandbox + capping concurrency lets both rustc *and* the assembly copy work.

> If `fx set`/`fx gen` regenerates the workspace rc and the template edit was lost, re-apply
> the two lines above.

## Build artifacts (bringup.x64)

| name | path (under build dir) |
|---|---|
| `zircon-a` zbi | `obj/products/bringup/product_bundle.x64/product_bundle/system_a/fuchsia.zbi` |
| kernel zbi | `kernel.eng.zbi` |

## Next

Once `fx build` is green: `ffx emu start` (femu) to boot bringup.x64 and confirm the
toolchain end-to-end, then move to the `lagos` arm64 board config (see
[05-next-steps.md](05-next-steps.md)).
