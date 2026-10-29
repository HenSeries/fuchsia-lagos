# 18 — Remote shell over USB

Since [attempt 27](17-usb-peripheral.md) the phone shows up on the host as a
USB CDC-Ethernet device and netsvc answers on the link. `loglistener`
already streams the logs. This doc covers running commands.

## Attempt 27: netruncmd reaches netsvc but cannot launch

```
[netsvc] net cmd: uname -a; ...
[netsvc] netsvc: cannot launch /boot/bin/sh: -24: failed to send launch message: -24 (ZX_ERR_PEER_CLOSED)
```

netsvc runs `/boot/bin/sh -c <cmd>` with `fdio_spawn_etc()`, which needs
`/svc/fuchsia.process.Launcher`. netsvc's manifest never `use`d it, and the
bootstrap shard never offered it, so the spawn request hit a closed channel.

## Attempt 28: give netsvc the launcher

- `src/bringup/bin/netsvc/meta/netsvc.cml` now `use`s
  `fuchsia.process.Launcher`.
- `netsvc.shard.cml` offers it `from: "parent"`, the same source
  console-launcher gets it from.

Result: the first remote command works.

```
$ tools/lagos-sh 'echo hello from fuchsia on lagos'
hello from fuchsia on lagos
$ tools/lagos-sh 'ls /'
d  0        0 boot
d  1        0 dev
d  0        0 pkg
d  0        0 svc
d  1        0 tmp
```

`/boot/bin` holds about 70 tools (`ps top memgraph kstats lsusb lspci kill
threads vmaps dd df dlog component …`). bringup has no `cat` or `head`.

Two issues remained:

- **No PATH.** netsvc spawns sh with an empty environment, so `ps` was
  `NOT_FOUND`. Fixed host-side: `lagos-sh` prefixes every command with
  `export PATH=/boot/bin:/pkg/bin`.
- **`ps`: `cannot obtain root job: ZX_ERR_PEER_CLOSED`.** The spawned shell
  inherits netsvc's `/svc`, which has no `fuchsia.kernel.RootJob`.

## Attempt 29

netsvc also gets `fuchsia.kernel.RootJob`, `RootJobForInspect` and
`Stats` from parent, which is how console-launcher has them. That's for
`ps`, `top`, `kstats` and `memgraph`.

## `tools/lagos-sh`

```bash
tools/lagos-sh                  # interactive prompt, one command per line
tools/lagos-sh 'ps'             # one command
tools/lagos-sh --log            # stream the device log (loglistener)
```

How it works:

1. It starts `loglistener` in the background.
2. It sends `export PATH=…; echo BEGIN; <cmd>; echo END $?` with
   `netruncmd`.
3. It prints the debuglog lines between the two markers with their
   `[time] pid.tid [tag]` prefixes stripped, and reports a non-zero exit
   status.

**Limits:** each command is a separate `sh -c`, so `cd` and variables don't
carry over. There's no stdin, so interactive programs won't work. Output
travels over UDP debuglog packets, so a very large dump can drop lines.

## Attempt 29 result: `ps` works

[Full output](../logs/attempt29-remote-shell-ps.txt). `tools/lagos-sh ps` prints the whole
job/process tree of the running phone:

```
TASK              PSS PRIVATE  SHARED   STATE NAME
j: 1051        176.1M  160.2M                 root
  p: 1201       10.7M   10.3M   5280K         bin/component_manager
      p: 2391  139.1M  138.3M   4324K         sysmem.cm
      p: 2420 2508.2K   1056K   8536K         archivist.cm
      p: 3071 2228.1K   1192K   4940K         driver_manager.cm
      p: 3965  721.5K    368K   3404K         netsvc.cm
      p: 9203  893.5K    400K   5716K         net:sh          <- the remote shell
      p: 9330  400.9K    236K   2804K         /boot/bin/ps
      p: 7594 3742.5K   1728K   10.2M         mt-musb.cm (+2 more)   <- USB driver host
      ...
```

What still doesn't work, and why:

| command | result | cause |
|---|---|---|
| `kstats` | `Cannot obtain info resource` | needs `fuchsia.kernel.InfoResource` (not offered to netsvc yet) |
| `threads` | `libinspector.so` NOT_FOUND, crash | the netsvc-spawned shell's loader can't find that lib |
| `memgraph \| dd` | crash | `dd` can't read stdin, so the pipe broke; run `memgraph` alone |
| `lsusb` | NOT_FOUND | lists `/dev/class/usb-device` (USB *host* side) |
