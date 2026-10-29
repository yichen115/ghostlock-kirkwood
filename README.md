# GhostLock for Google TV Streamer (kirkwood / MT8696)
### Single-file, per-boot temporary root + interactive root shell

> **⚠️ Build-specific security research software.**
> Use it only on hardware you own or are explicitly authorized to test.
> It is **not** a universal root tool, it does **not** unlock the bootloader,
> it does **not** survive a reboot, and a kernel exploit can crash or hang the
> device. Read [Safety, legal, risk](#6-safety-legal-risk) before running it.

**Validated configuration**

| Item | Value |
|---|---|
| Device | Google TV Streamer (`kirkwood`), MediaTek MT8696 |
| Firmware / build | `UTTK.260317.003` / `15205007` (Android 14, SDK 34) |
| Fingerprint | `google/kirkwood/kirkwood:14/UTTK.260317.003/15205007:user/release-keys` |
| Kernel | `5.15.180-android14-11-gf55c0c36ffcd-ab13512086` (GKI release, CI build 13512086) |
| Security patch | `2026-04-01` (userspace SPL; this does **not** imply the kernel is patched) |
| Userspace | 32-bit only (`armeabi-v7a,armeabi`) |
| Boot chain | bootloader `locked`, AVB `green`, verity `enforcing` |
| RAM | 4 GB class (`MemTotal ~3,962,200 kB`) |
| Vulnerability | **CVE-2026-43499** ("GhostLock") — futex PI `remove_waiter()` leaves a stale `pi_blocked_on`, stale-waiter UAF → `sched_setattr` PI walk → `rb_erase` 8-byte write |

---

## 1. What this is

`ghostlock-kirkwood-oneclick.sh` is a **single self-extracting file** that:

1. checks the device/kernel,
2. unpacks the exploit, the AArch32 helper, a root agent and a root-shell
   client into `/data/local/tmp/.ghostlock-oneclick`,
3. exploits CVE-2026-43499 to write `selinux_state` (SELinux → permissive) and
   the current task's `cred`/`real_cred` (UID 0),
4. starts a UID-0 agent and attaches an **interactive root shell on a real
   pty**.

You push **one file** and run it from an interactive `adb shell`:

```bash
adb push ghostlock-kirkwood-oneclick.sh /data/local/tmp/
adb shell
sh /data/local/tmp/ghostlock-kirkwood-oneclick.sh
```

Root is **volatile**: rebooting restores SELinux enforcing and the original
credentials. Nothing is flashed, no `su`/Magisk is installed, no network
service is opened, and the only writes are under `/data/local/tmp`.

---

## 2. Compatibility — hard requirements

**Same model is not enough.** The exploit chain is derived from one exact
kernel image; offsets, struct layouts, the perf capture-witness window and the
compat-syscall stack geometry must all match.

The bundle refuses to run unless `uname -r` is exactly
`5.15.180-android14-11-gf55c0c36ffcd-ab13512086`.

Check a candidate device (read-only, no root required):

```bash
adb push check-kirkwood.sh /data/local/tmp/
adb shell sh /data/local/tmp/check-kirkwood.sh
# VERDICT: COMPATIBLE ...  -> ok to try the bundle
# VERDICT: NOT COMPATIBLE  -> do not run it; see section 7
```

| Check | Required value |
|---|---|
| `uname -r` | `5.15.180-android14-11-gf55c0c36ffcd-ab13512086` |
| `ro.product.device` | `kirkwood` |
| `ro.build.fingerprint` | `google/kirkwood/kirkwood:14/UTTK.260317.003/15205007:user/release-keys` |
| `ro.build.version.security_patch` | `2026-04-01` |
| `ro.build.version.sdk` | `34` |
| `ro.boot.verifiedbootstate` | `green` |
| `ro.boot.vbmeta.device_state` | `locked` |
| `ro.product.cpu.abilist` | contains `armeabi-v7a` |
| `MemTotal` | ~3.9 GB (4 GB class) |
| SELinux before the run | `Enforcing` |

> A device that received a **newer OTA** usually has a **different kernel
> build**. Any different kernel invalidates this bundle's offsets / capture
> geometry, so do not expect this prebuilt binary to work. In addition,
> kernels that contain the upstream fix (`3bfdc63936dd…`, author-date
> 2026-04-08, merged in 7.1-rc1 and backported to stable 5.10.262 / 6.1.176 /
> 6.12.86 / 7.0.4 and later branches) are **not vulnerable to
> CVE-2026-43499**; the chain is dead there. Build date alone does not prove
> patch status — verify the target kernel source (section 7.1.3). Always run
> the compatibility check first; **never** patch the kernel-string check away.

---

## 3. Quick start

### 3.1 Interactive root shell (the intended use)

```bash
sha256sum -c SHA256SUMS
adb push ghostlock-kirkwood-oneclick.sh /data/local/tmp/
adb shell
sh /data/local/tmp/ghostlock-kirkwood-oneclick.sh
```

Expected output after ~40–60 s:

```
[+] ROOT AGENT READY: ready pid=... abstract=... pty=1
[i] entering interactive root shell (exit to leave)
:/ # id
uid=0(root) gid=0(root) ... context=kernel
```

### 3.2 Other modes

```bash
sh ghostlock-kirkwood-oneclick.sh --exec "id; tty"   # one command, clean pipe output
sh ghostlock-kirkwood-oneclick.sh --no-shell          # start the root agent only
sh ghostlock-kirkwood-oneclick.sh --extract-only      # unpack + self-test, no exploit
sh ghostlock-kirkwood-oneclick.sh --perf-loops 20000  # sampling loops (default 20000)
sh ghostlock-kirkwood-oneclick.sh --settle-us 80000   # split settle time
```

### 3.3 Rules

* **One attempt per boot.** Never retry on the same boot after `W1 PASS` /
  `W2 FAIL`: SELinux may already be permissive with no root. The script tells
  you when a reboot is required.
* **Never kill the parked `ghostlock-lab` process.** It holds the fake-cred
  page; reboot is the only safe cleanup boundary.
* If the device hangs/panics: power-cycle it (on our lab unit a USB-controlled
  power switch was used).

### 3.4 Cleanup

```bash
adb shell "/data/local/tmp/.ghostlock-oneclick/kirkwood_root_sh \
  --name <abstract-from-ready-file> \
  --exec 'rm -f /data/local/tmp/root_proof_uid0 /data/local/tmp/root_agent_ready \
          /data/local/tmp/root_proof_broker; \
          rm -rf /data/local/tmp/.ghostlock-oneclick; echo CLEANED'"
adb reboot            # restores SELinux enforcing and reclaims the parked victim
```

---

## 4. How it works (high level)

The bundle is a thin packer around the GhostLock exploit ported to `kirkwood`.

1. **KASLR leak** — perf sampling of a syscall path leaks a kernel text
   pointer; the runtime `_text` base is the 2 MB-aligned anchor.
2. **Capture witness** — `perf_event_open` + `SAMPLE_REGS_INTR` proves that a
   sprayed `io_uring` ring page is mapped at a known `mm_struct` PFN
   (pagemap is zeroed on this kernel). The witness instruction window comes
   from the **exact** release `vmlinux` (`io_uring_mmap`, the
   `ldr x0, [ctx, #rings]` site).
3. **Reclaim** — KernelSnitch leaks an `mm_struct`; SLUB/io_uring order-2 page
   reclaim frees that slab page and reallocates it as an io_uring ring mapping
   (16 KB, 16 objects).
4. **Carrier** — a 32-bit (`AArch32`) `_newselect` syscall overlays a fake
   `rt_mutex_waiter` on the helper's stack; a futex `WAIT_REQUEUE_PI` leaves a
   stale `pi_blocked_on` in the victim task.
5. **Write #1 — SELinux off** — `sched_setattr` on the victim triggers an
   `rt_mutex_adjust_prio_chain` walk into the fake waiter; `rb_erase` performs
   a controlled 8-byte write that zeroes `selinux_state`
   (`enforcing=0`, `initialized=0`). Verified by `getenforce` → `Permissive`.
6. **Write #2 — credentials** — a second, independent fresh reclaim builds a
   fake `cred` page and writes it to the victim's `task->cred` / `real_cred`.
   The child verifies UID 0 over IPC.
7. **Handoff** — the UID-0 child execs a small agent that writes proof files,
   listens on an `AF_UNIX` abstract socket, and serves a **pty** `sh` to a
   relay client. No network sockets, no persistent artifacts.

This port added, on top of the public GhostLock research:

* exact `kirkwood` kernel/offset verification (`boot_b` kernel is
  **byte-identical** to the matching GKI release `Image.release`);
* runtime KASLR base for every static symbol access;
* the correct rb-color handling for the zero-write (`RED` leaf) and the
  preserve-initialized variant;
* SELinux-first ordering with two independent fresh reclaims (the recipe
  validated by the TCL C855 port);
* a single-file packer and a UID-0 pty shell agent.

Not included by design: su/Magisk/KernelSU, persistence, boot image or
partition modification, network services, telemetry.

---

## 5. Evidence (what was validated)

On our unit (build above, clean boot, SELinux enforcing), the final artifact
(`ghostlock-kirkwood-oneclick.sh`, sha256
`a4968b9bb9fc451066e060d66739a2af5e05640827df8ddcd1ed46b32beb1150`)
produced:

```
[+] TCL W1 PASS: SELinux disabled via fresh reclaim A (enforce readback=0)
[+] TCL W2 PASS: cred write via fresh reclaim B; victim pid=... parent_uid=2000
[+] TCL victim root verified; parent uid=2000 remains unchanged
[+] ROOT AGENT READY: ready pid=... abstract=... pty=1
:/ # id
uid=0(root) gid=0(root) ... context=kernel
:/ # tty
/dev/pts/1
:/ # ls /proc/self/fd
# only 0/1/2 -> /dev/pts/1 plus a proc entry; no /dev/ptmx leak
```

After `exit` + cleanup + power-cycle: `getenforce` → `Enforcing`, and
`/data/local/tmp` contained no project artifacts.

The kernel/offset side of the chain was independently verified:

* the running kernel image (`boot_b`) is byte-identical to the GKI release
  `Image.release` of the same CI build;
* 21 key symbols in `/proc/kallsyms` match the offset table exactly;
* `/sys/kernel/btf/vmlinux` is byte-identical to the release vmlinux `.BTF`;
* physical kernel load is `0x52000000` (`/proc/iomem`: `52010000-541effff`),
  stable across repeated boots.

These checks make the chain reproducible on **exactly this build**, and they
also define what must be re-derived for any other build (section 7).

---

## 6. Safety, legal, risk

* **Authorized hardware only.** Rooting a device may void warranties and may
  violate terms of service. You are responsible for the device and for local
  law.
* **Engine bug = possible panic/hang.** `panic_on_oops=1` is set on this
  kernel; a wrong offset or an unexpected state can hang the device until a
  power cycle. One attempt per boot; do not retry after a partial write.
* **Temporary by design.** The bootloader is locked and AVB is green, so there
  is no safe persistent-root path. Rebooting restores the original state.
* **No secret extraction.** The bundle does not read user data, DRM keys or
  attestation secrets; it only toggles SELinux and process credentials.
* **No redistribution of firmware.** Do not publish device dumps or keys.

---

## 7. If the chain does not work — adaptation guide

The bundle exits with `[!] unsupported kernel` when `uname -r` mismatches.
That is intentional: running with wrong offsets can crash the kernel.
The following is the checklist we used to port the chain to `kirkwood`; it is
also the shortest path to adapt it to a different Google TV / Android TV build.

### 7.1 Decide why it doesn't match

1. **Different kernel string** → the kernel image differs (newer OTA, different
   GKI build, different SoC family). You need a new target profile (7.2).
2. **Kernel string matches but the device is a different model** → not
   supported; stop.
3. **Is the kernel patched?** — The upstream fix is
   `3bfdc63936dd4773109b7b8c280c0f3b5ae7d349`
   ("rtmutex: Use waiter::task instead of current in remove_waiter()",
   author-date 2026-04-08; merged in 7.1-rc1; backported to stable 5.10.262,
   6.1.176, 6.12.86, 7.0.4 and later). If the kernel contains that change —
   `remove_waiter()` must dequeue and clear `waiter->task->pi_blocked_on`
   (a local `waiter_task`), not `current->pi_blocked_on`, and pass
   `waiter_task` to `rt_mutex_adjust_prio_chain()` — then **CVE-2026-43499 is
   fixed** and this chain cannot work; you need a different vulnerability.
   Build date alone is not proof (GKI/LTS backport timing differs), so check
   the kernel source/patch when you can. References:
   [upstream commit](https://git.kernel.org/linus/3bfdc63936dd4773109b7b8c280c0f3b5ae7d349),
   [CVE-2026-43499 tracker](https://security-tracker.debian.org/tracker/CVE-2026-43499),
   [NebuSec IonStack research](https://nebusec.ai/research/ionstack-part-2/).
4. **Userspace is 64-bit only** (no `armeabi-v7a`) → the AArch32
   `_newselect` carrier cannot be used; you must port the native `pselect`
   carrier from upstream GhostLock (or another stack-overlay syscall).
5. **RAM size / zone layout differs** (e.g., 2 GB or 3 GB boxes) → the
   KernelSnitch scan range and SLUB/PCP reclaim tuning must be recalculated
   (7.5).

### 7.2 Start from the exact kernel image

You need the kernel of the **target build**:

* from an OTA payload / `boot.img` / `init_boot.img`, or an eMMC dump
  (`boot_b` slot is usually the active one; verify with
  `ro.boot.slot_suffix`/kernel string);
* or the matching GKI CI artifact: tag `android14-5.15-YYYY-MM_rX` +
  `System.map` / `vmlinux` / `Image` (e.g. our kernel is
  `android14-5.15-2025-05_r1`, CI build `13512086`).

Record the sha256 of the kernel image and the kernel version string. Confirm
the kernel is **not patched** (7.1.3).

### 7.3 Re-derive the offset table

From the matching `System.map` + `vmlinux` (BTF) compute at least:

* text range: `_text`, `_stext`, `_etext`;
* core objects: `init_task`, `init_cred`, `init_uts_ns`, `init_user_ns`,
  `empty_zero_page`, `root_task_group`, `selinux_state`, `selinux_blob_sizes`,
  `security_hook_heads`, `kmalloc_caches`, `ashmem_misc`/`ashmem_fops`,
  `loggers`/`nfulnl_logger`, `sysctl_bootid`, `system_unbound_wq`;
* `struct task_struct`: `pi_lock`, `pi_waiters`, `pi_top_task`,
  `pi_blocked_on`, `atomic_flags`, `cred`, `real_cred`, `comm`, `mm_owner`;
* `struct futex_q`: `rt_waiter`; `struct rt_mutex_waiter` layout;
* `struct mm_struct` size (the `kmem_cache_create_usercopy("mm_struct", …)`
  size), `struct cred`, `struct user_namespace`, `struct pipe_buffer`;
* `selinux_state` layout (enforcing/checkreqprot/initialized/policycap).

Use BTF (`pahole -F btf`, or the repo's offset generators) for structs and
`System.map`/`nm` for symbols. Cross-check a few symbols on the device later
via `/proc/kallsyms` once you have a first successful run.

### 7.4 Recompute the capture witness (perf-regs)

The witness must prove the `io_uring` mapping. In the matching `vmlinux`,
disassemble `io_uring_mmap` and find the instruction that loads
`ctx->rings` (or `ctx->sq_sqes`) into the sampled register (ours is
`ldr x0, [x8]` at link offset `0x9454bc`, valid window `0x9454bc..0x945534`,
register `x0`). Compare the *runtime* anchor with `_text`: the witness uses
`anchor + file_offset`.

Failure signature: `verdict=0`, `hit=0`, `near=0` for every pair. Check:

* `perf_event_paranoid` allows shell perf (`-1` on our build);
* the kernel text pointer is really the KASLR base (2 MB alignment);
* your IP window/register are correct for this kernel;
* sampling loops/attempts are sufficient (our default 20000 loops, 5 attempts;
  attempts are clamped to the compiled array size).

### 7.5 Recompute reclaim geometry (SLUB / zones)

From `CONFIG_SLAB*`, `/proc/slabinfo` and `/proc/zoneinfo`:

* `mm_struct` slab: size = ALIGN(size, 64), objects/order-2 page = 16384/size
  (ours: 1024 B → 16 objects, order 2);
* `slub_min_partial = ilog2(size)/2` (ours 5), `cpu_partial = 6` for size ≥ 1024
  (5.15 rule);
* zone layout: DMA32 vs Normal and their managed-page ranges determine the
  KernelSnitch scan window (`direct_map_end`) and PCP drain/burst tuning
  (4 GB with a 1 GB Normal zone differs from 2 GB/3 GB boxes).

### 7.6 Recompute the compat-select stack layout

Disassemble the target kernel's `__arm64_compat_sys_select`,
`do_compat_select`, `compat_core_sys_select`:

* function frame sizes (ours: 0x10 / 0x80 / 0x1b0);
* fd-set bitmaps on the stack (ours at `syscall SP-0x200`, 40-byte sets,
  `nfds=320`);
* the futex waiter position relative to the syscall SP (ours at `SP-0x1d0`;
  waiter = bitmaps + 0x30).

Validate the geometry with the project's QEMU harness and host tests before
going back to hardware.

### 7.7 Write-path sanity

* **SELinux zero write**: target `selinux_state`, value `0`; for the zero/leaf
  write the `rb_erase` victim must be **RED** (bit0 clear), otherwise the
  rebalance walk dereferences the fake parent. The preserve-initialized
  variant (non-zero child) is the alternative when a clean zero is not wanted.
* **Cred write**: fake `cred` page, `task->cred` and `real_cred`, `user_ns`,
  `init_cred`; the child must verify UID 0 before the broker exec; SELinux must
  already be off before `execve` of the shell/agent.
* Keep the "fresh reclaim before each write" ordering: SELinux first, cred
  second. Do not reuse the already-captured page for the second write unless
  you re-arm every waiter/lock field and re-validate the color.

### 7.8 Failure signature table

| Symptom | Likely cause | Action |
|---|---|---|
| `[!] unsupported kernel` | build mismatch | do not run; adapt (7.2–7.6) |
| `capture witness verdict=0`, all `hit=0` | wrong witness window/register, perf restricted, or workload timing | verify offsets; `perf_event_paranoid`; retry; try `--perf-loops 20000` |
| `complete=0` after a long sampling phase | sampling phase not finished; witness bailed | same-boot retry if nothing was written; otherwise reboot |
| `W1 PASS`, `W2 FAIL` | second capture/flake or reclaim state | **reboot**, then retry (script tells you) |
| split crash / hang | stack geometry or settle mismatch, wrong fake-waiter fields | verify with exact vmlinux + QEMU; do not retry same boot |
| creds OK but no root shell | SELinux not actually off, agent exec blocked, or client/agent version mismatch | check `getenforce`; verify agent is the same revision as the client |
| shell connects but no prompt | stdin not a tty, or start command from non-interactive `adb shell` | run from interactive `adb shell`; or use `--exec`/`--no-shell` |

### 7.9 Rebuild and repack

* Toolchain: Android NDK clang (static), `-DGHOST_DEVICE_<TARGET>` profile,
  aarch64 main binary + AArch32 helper (if the carrier needs it).
* Run host/QEMU tests first; one attempt per boot on hardware.
* Regenerate the single-file bundle with `make_oneclick.py` (gzip + base64,
  fixed member order/mtime/uid/gid) and update `SHA256SUMS`.
* Any change to the embedded lab/helper/agent/client requires a new bundle
  hash; the bundle is only as trustworthy as its embedded payload.

---

## 8. Verify the download

```bash
sha256sum -c SHA256SUMS
```

`ghostlock-kirkwood-oneclick.sh`: **14,426,154 bytes**,
sha256 `a4968b9bb9fc451066e060d66739a2af5e05640827df8ddcd1ed46b32beb1150`.
The bundle is a fixed gzip+base64 payload; its four embedded artifacts are
listed in `SHA256SUMS` for post-extraction checking:

```bash
# on device, after --extract-only:
sha256sum /data/local/tmp/.ghostlock-oneclick/*
```

---

## 9. Credits & license

This port builds directly on public security research. Many thanks to:

* [NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia) — original
  GhostLock/IonStack research (Apache-2.0).
* [k-o-n-t-o-r/ghostlock-sabrina](https://github.com/k-o-n-t-o-r/ghostlock-sabrina)
  — Sabrina reference implementation.
* [R0rt1z2/GhostLock](https://github.com/R0rt1z2/GhostLock) — GhostLock
  implementation and target profiles.
* [isec-tugraz/KernelSnitch](https://github.com/isec-tugraz/KernelSnitch) —
  futex timing side channel (MIT).
* The TCL C855 / T653T01 port (`ghostlock-tcl-c855`, Apache-2.0) — the
  ARM32 `_newselect` carrier, safety gates, SELinux-first recipe and
  QEMU/hardware validation approach that this `kirkwood` port follows.
* The Android Common Kernel and Linux kernel futex/rbtree sources, and the
  public CVE-2026-43499 record.

License: Apache-2.0 for this repository's code and documentation; embedded
third-party components keep their own licenses. See [`LICENSE`](LICENSE),
[`NOTICE.md`](NOTICE.md), [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
and [`LICENSES/`](LICENSES/). Upstream projects without published license
metadata remain subject to their authors' rights; acknowledgements do not
grant extra rights.

---

## 10. FAQ

**Does it persist?** No. Reboot restores SELinux enforcing and normal
credentials. Locked bootloader + AVB green make persistent root unsafe.
**Will it work on another Google TV Streamer?** Only if `uname -r` (and
ideally the full fingerprint) matches. Use `check-kirkwood.sh`.
**Why no `su`?** We only switch `cred`s on a parked child and expose an
`AF_UNIX` pty shell; there is no persistent daemon to manage.
**Why does the second stage sometimes fail?** The perf-based capture witness
is probabilistic; the capture gate refuses rather than risk a blind write.
Reboot and retry.
**Can I integrate it into an app?** Not as-is: the bundle needs an interactive
ADB shell (or `--exec`). The design is deliberately not a persistent service.
**Can I publish it?** The code is Apache-2.0 with third-party notices; keep
attribution and do not publish firmware dumps/keys.

---

## 中文版（简体）

# 适用于 Google TV Streamer（kirkwood / MT8696）的 GhostLock
### 单文件、每次开机一次的临时 root + 交互式 root shell

> **⚠️ 仅限特定 build 的安全研究软件。**
> 只能在你自己拥有或获得明确授权的硬件上使用。它不是通用 root 工具，
> 不解锁 bootloader，不能跨重启存活；内核漏洞利用可能导致设备崩溃或卡死。
> 运行前请阅读[安全、法律与风险](#6-安全法律与风险)。

**已验证配置**

| 项目 | 值 |
|---|---|
| 设备 | Google TV Streamer（`kirkwood`），MT8696 |
| 固件/build | `UTTK.260317.003` / `15205007`（Android 14，SDK 34） |
| 指纹 | `google/kirkwood/kirkwood:14/UTTK.260317.003/15205007:user/release-keys` |
| 内核 | `5.15.180-android14-11-gf55c0c36ffcd-ab13512086`（GKI release，CI build 13512086） |
| 安全补丁 | `2026-04-01`（userspace SPL；**不**代表内核已打补丁） |
| 用户态 | 仅 32 位（`armeabi-v7a,armeabi`） |
| 启动链 | bootloader `locked`、AVB `green`、verity `enforcing` |
| 内存 | 4GB 级（`MemTotal ~3,962,200 kB`） |
| 漏洞 | **CVE-2026-43499**（GhostLock）：futex PI `remove_waiter()` 遗留 `pi_blocked_on` → 过期 waiter UAF → `sched_setattr` PI 遍历 → `rb_erase` 8 字节写 |

## 1. 这是什么

`ghostlock-kirkwood-oneclick.sh` 是一个**单文件自解压脚本**：

1. 检查设备/内核；
2. 把漏洞程序、AArch32 helper、root agent、root shell 客户端解包到 `/data/local/tmp/.ghostlock-oneclick`；
3. 利用 CVE-2026-43499 写 `selinux_state`（SELinux 变 permissive）和当前任务的 `cred`/`real_cred`（uid 0）；
4. 启动 uid=0 的 agent，并通过真实 pty 提供**交互式 root shell**。

只需要 push **一个文件**，在交互式 `adb shell` 里执行：

```bash
adb push ghostlock-kirkwood-oneclick.sh /data/local/tmp/
adb shell
sh /data/local/tmp/ghostlock-kirkwood-oneclick.sh
```

root 是**临时的**：重启后 SELinux 恢复 enforcing、凭据恢复。不刷机、不装
su/Magisk、不开网络服务，只写 `/data/local/tmp`。

## 2. 兼容性（硬性要求）

**只看型号不够。** 整条链由某一版精确内核镜像推导：偏移、结构体布局、
perf capture witness 窗口、compat syscall 栈几何都必须匹配。

脚本在 `uname -r` 不等于 `5.15.180-android14-11-gf55c0c36ffcd-ab13512086`
时会直接拒绝运行。

只读检查目标机（无需 root）：

```bash
adb push check-kirkwood.sh /data/local/tmp/
adb shell sh /data/local/tmp/check-kirkwood.sh
# VERDICT: COMPATIBLE   -> 可以尝试
# VERDICT: NOT COMPATIBLE -> 不要运行，按第 7 节适配
```

| 检查项 | 要求值 |
|---|---|
| `uname -r` | `5.15.180-android14-11-gf55c0c36ffcd-ab13512086` |
| `ro.product.device` | `kirkwood` |
| `ro.build.fingerprint` | `google/kirkwood/kirkwood:14/UTTK.260317.003/15205007:user/release-keys` |
| `ro.build.version.security_patch` | `2026-04-01` |
| `ro.build.version.sdk` | `34` |
| `ro.boot.verifiedbootstate` | `green` |
| `ro.boot.vbmeta.device_state` | `locked` |
| `ro.product.cpu.abilist` | 包含 `armeabi-v7a` |
| `MemTotal` | 约 3.9GB（4GB 级） |
| 运行前 SELinux | `Enforcing` |

> 收到**较新 OTA** 的机器通常会是**另一个内核 build**；任何不同的内核都会让本
> 预编译包的偏移/capture 几何失效，不能指望直接运行。此外，包含上游修复
> （`3bfdc63936dd…`，作者日期 2026-04-08，合入 7.1-rc1，并回移到 stable
> 5.10.262 / 6.1.176 / 6.12.86 / 7.0.4 及之后分支）的内核**不受
> CVE-2026-43499 影响**，本链在那些机器上无效。仅凭 build 日期不能证明是否
> 已修，能拿到内核源码时应直接检查（7.1.3）。必须先跑兼容性检查；**不要**为了
> 强行运行而改掉脚本里的内核字符串检查。

## 3. 快速开始

### 3.1 交互式 root shell（推荐用法）

```bash
sha256sum -c SHA256SUMS
adb push ghostlock-kirkwood-oneclick.sh /data/local/tmp/
adb shell
sh /data/local/tmp/ghostlock-kirkwood-oneclick.sh
```

约 40–60 秒后应看到：

```
[+] ROOT AGENT READY: ready pid=... abstract=... pty=1
[i] entering interactive root shell (exit to leave)
:/ # id
uid=0(root) gid=0(root) ... context=kernel
```

### 3.2 其他模式

```bash
sh ghostlock-kirkwood-oneclick.sh --exec "id; tty"   # 单条命令（干净 pipe 输出）
sh ghostlock-kirkwood-oneclick.sh --no-shell          # 只启动 root agent
sh ghostlock-kirkwood-oneclick.sh --extract-only      # 只解包自检
sh ghostlock-kirkwood-oneclick.sh --perf-loops 20000  # 采样循环数（默认 20000）
sh ghostlock-kirkwood-oneclick.sh --settle-us 80000   # split 稳定等待
```

### 3.3 规则

* **每次开机只能尝试一次。** 出现 `W1 PASS` / `W2 FAIL` 后不要在同一 boot
  重试：SELinux 可能已经 permissive 且没有 root。脚本会提示何时必须重启。
* **不要 kill 停住的 `ghostlock-lab` 进程**：它持有 fake-cred 页；重启是唯一安全清理边界。
* 设备卡死/panic：断电重启（实验室里可用 USB 控制电源）。

### 3.4 清理

```bash
adb shell "/data/local/tmp/.ghostlock-oneclick/kirkwood_root_sh \
  --name <ready 文件里的 abstract> \
  --exec 'rm -f /data/local/tmp/root_proof_uid0 /data/local/tmp/root_agent_ready \
          /data/local/tmp/root_proof_broker; \
          rm -rf /data/local/tmp/.ghostlock-oneclick; echo CLEANED'"
adb reboot            # 恢复 SELinux enforcing，回收 parked victim
```

## 4. 原理（概要）

单文件只是打包器，内部是移植到 `kirkwood` 的 GhostLock 链：

1. **KASLR 泄漏**：perf 采样的系统调用路径泄漏内核文本指针，得到 2MB 对齐的运行时 `_text`。
2. **capture witness**：用 `perf_event_open`+`SAMPLE_REGS_INTR` 证明 spray 的 `io_uring` ring 页映射到已知 `mm_struct` PFN（本内核 pagemap 被清零）。witness 指令窗口来自**精确**的 release `vmlinux`（`io_uring_mmap` 中 `ldr x0, [ctx, #rings]` 处）。
3. **回收**：KernelSnitch 泄漏 `mm_struct`；SLUB/io_uring 的 order-2 页回收把该 slab 页重新分配成 io_uring ring 映射（16KB，16 对象）。
4. **载体**：32 位（AArch32）`_newselect` 在 helper 栈上覆盖 fake `rt_mutex_waiter`；futex `WAIT_REQUEUE_PI` 在 victim 任务里留下过期 `pi_blocked_on`。
5. **写 #1 — 关 SELinux**：对 victim 执行 `sched_setattr`，触发 `rt_mutex_adjust_prio_chain` 走进 fake waiter；`rb_erase` 受控 8 字节写把 `selinux_state` 清零（`enforcing=0`、`initialized=0`），`getenforce` 读回 `Permissive`。
6. **写 #2 — 凭据**：第二次独立 fresh reclaim 构造 fake `cred` 页，写入 victim 的 `task->cred`/`real_cred`；子进程通过 IPC 验证 uid=0。
7. **交接**：uid=0 子进程 exec 小型 agent，写 proof 文件、监听 `AF_UNIX` 抽象 socket，并通过 pty 为 relay 客户端提供 root `sh`。无网络、无持久化。

本移植相对公开 GhostLock 研究新增：`kirkwood` 精确偏移验证（`boot_b` 内核与对应 GKI
release `Image.release` **逐字节一致**）、所有静态符号访问使用运行时 KASLR 基址、
zero 写正确的 rb color（RED 叶子）、SELinux-first 两次独立 fresh reclaim（TCL C855
验证过的配方）、单文件打包器与 uid0 pty agent。

设计上不包含：su/Magisk/KernelSU、持久化、改 boot/分区、网络服务、遥测。

## 5. 验证结果

在我们的设备（上述 build、干净 boot、SELinux enforcing）上，最终产物
（sha256 `a4968b9b…b1150`）实测输出：

```
[+] TCL W1 PASS: SELinux disabled via fresh reclaim A (enforce readback=0)
[+] TCL W2 PASS: cred write via fresh reclaim B; victim pid=... parent_uid=2000
[+] TCL victim root verified; parent uid=2000 remains unchanged
[+] ROOT AGENT READY: ready pid=... abstract=... pty=1
:/ # id
uid=0(root) gid=0(root) ... context=kernel
:/ # tty
/dev/pts/1
```

`exit` + 清理 + 断电重启后：`getenforce` → `Enforcing`，`/data/local/tmp`
无项目残留。

内核/偏移侧也已独立验证：运行内核（`boot_b`）与同 CI build 的 GKI release
`Image.release` 逐字节一致；`/proc/kallsyms` 21 个关键符号与偏移表完全匹配；
`/sys/kernel/btf/vmlinux` 与 release vmlinux `.BTF` 逐字节一致；物理加载地址
`0x52000000`（`/proc/iomem`: `52010000-541effff`）跨多次启动稳定。

这些验证既说明本 build 上可复现，也定义了换 build 时必须重新推导的内容（第 7 节）。

## 6. 安全、法律与风险

* **仅限授权硬件。** 提权可能失去保修、违反服务条款；设备和当地法律后果由你负责。
* **引擎 bug 可能 panic/卡死。** 本内核 `panic_on_oops=1`；偏移不对或状态异常可能卡死到断电。每次开机只尝试一次；部分写入后不要重试。
* **设计上就是临时的。** bootloader 锁定 + AVB green，没有安全的持久 root 路径；重启恢复原状。
* **不提取秘密。** 不读取用户数据、DRM key、attestation secret；只切 SELinux 与进程凭据。
* **不要分发固件。** 不要发布设备 dump 或密钥。

## 7. 打不通时如何修正匹配（适配指南）

脚本在 `uname -r` 不匹配时会以 `[!] unsupported kernel` 退出——这是故意的：
错误偏移可能直接崩内核。下面是把这个链移植到 `kirkwood` 时用的清单，也是适配到
其他 Google TV / Android TV build 的最短路径。

### 7.1 先判断原因

1. **内核串不同** → 内核镜像不同（新 OTA、不同 GKI build、不同 SoC 家族），需要新 target profile（7.2）。
2. **内核串相同但型号不同** → 不支持，停止。
3. **内核是否已打补丁？** —— 上游修复是
   `3bfdc63936dd4773109b7b8c280c0f3b5ae7d349`
   （"rtmutex: Use waiter::task instead of current in remove_waiter()"，
   作者日期 2026-04-08；合入 7.1-rc1；回移到 stable 5.10.262、6.1.176、
   6.12.86、7.0.4 及之后）。若内核包含该改动——`remove_waiter()` 必须对
   `waiter->task`（局部 `waiter_task`）执行 dequeue 并清
   `waiter_task->pi_blocked_on`，而不是 `current->pi_blocked_on`，且把
   `waiter_task` 传给 `rt_mutex_adjust_prio_chain()`——则
   **CVE-2026-43499 已修复**，本链无效，需要换漏洞。仅凭 build 日期不能
   证明补丁状态（GKI/LTS 回移时间不同），能拿到内核源码时应直接核对。
   参考：[上游 commit](https://git.kernel.org/linus/3bfdc63936dd4773109b7b8c280c0f3b5ae7d349)、
   [CVE-2026-43499 tracker](https://security-tracker.debian.org/tracker/CVE-2026-43499)、
   [NebuSec IonStack 研究](https://nebusec.ai/research/ionstack-part-2/)。
4. **用户态仅 64 位**（无 `armeabi-v7a`）→ AArch32 `_newselect` 载体不可用；需移植上游的原生 `pselect` 载体（或其他栈覆盖系统调用）。
5. **内存大小/zone 布局不同**（2GB/3GB 机器）→ KernelSnitch 扫描范围与 SLUB/PCP 回收参数需重算（7.5）。

### 7.2 取得精确内核镜像

需要目标 build 的内核：

* 从 OTA / `boot.img` / `init_boot.img` / eMMC dump 提取（`boot_b` 通常是活动槽，用 `ro.boot.slot_suffix`/内核串确认）；
* 或对应 GKI CI 产物：tag `android14-5.15-YYYY-MM_rX` + `System.map`/`vmlinux`/`Image`（本机为 `android14-5.15-2025-05_r1`，CI build `13512086`）。

记录内核 sha256 与版本串，并确认未打补丁（7.1.3）。

### 7.3 重新推导偏移表

用匹配的 `System.map` + `vmlinux`（BTF）至少求出：

* 文本范围：`_text`、`_stext`、`_etext`；
* 核心对象：`init_task`、`init_cred`、`init_uts_ns`、`init_user_ns`、`empty_zero_page`、`root_task_group`、`selinux_state`、`selinux_blob_sizes`、`security_hook_heads`、`kmalloc_caches`、`ashmem_misc`/`ashmem_fops`、`loggers`/`nfulnl_logger`、`sysctl_bootid`、`system_unbound_wq`；
* `task_struct`：`pi_lock`、`pi_waiters`、`pi_top_task`、`pi_blocked_on`、`atomic_flags`、`cred`、`real_cred`、`comm`、`mm_owner`；
* `futex_q.rt_waiter`、`rt_mutex_waiter` 布局；
* `mm_struct` 大小（`kmem_cache_create_usercopy("mm_struct", …)` 的 size）、`cred`、`user_namespace`、`pipe_buffer`；
* `selinux_state` 布局（enforcing/checkreqprot/initialized/policycap）。

结构体用 BTF（`pahole -F btf` 或仓库的 offset 生成器），符号用 `System.map`/`nm`。
拿到第一次成功后，可在设备上用 `/proc/kallsyms` 交叉核对若干符号。

### 7.4 重算 capture witness

在匹配的 `vmlinux` 里反汇编 `io_uring_mmap`，找到把 `ctx->rings`（或 `ctx->sq_sqes`）
加载进被采样寄存器的指令（本机为偏移 `0x9454bc` 的 `ldr x0, [x8]`，有效窗口
`0x9454bc..0x945534`，寄存器 `x0`）。witness 使用 `运行时 anchor + 文件偏移`。

失败特征：`verdict=0`、每组 pair `hit=0`。排查：`perf_event_paranoid` 是否允许
shell perf（本机 `-1`）、anchor 是否为 2MB 对齐的内核文本基址、IP 窗口/寄存器是否
正确、采样循环/attempts 是否足够（默认 20000 loops、5 attempts；attempts 受二进制
数组长度限制）。

### 7.5 重算回收参数（SLUB / zone）

从 `CONFIG_SLAB*`、`/proc/slabinfo`、`/proc/zoneinfo` 计算：

* `mm_struct` slab：size = ALIGN(size,64)，order-2 页对象数 = 16384/size（本机 1024B → 16 对象，order 2）；
* `slub_min_partial = ilog2(size)/2`（本机 5），size≥1024 时 `cpu_partial=6`（5.15 规则）；
* zone 布局：DMA32/Normal 的 managed 页范围决定 KernelSnitch 扫描窗口（`direct_map_end`）与 PCP drain/burst 参数（4GB 且有 1GB Normal 与 2GB/3GB 机器不同）。

### 7.6 重算 compat-select 栈几何

反汇编目标内核的 `__arm64_compat_sys_select`、`do_compat_select`、
`compat_core_sys_select`：

* 各函数帧大小（本机 0x10 / 0x80 / 0x1b0）；
* 栈上的 fd_set bitmap（本机在 `syscall SP-0x200`，40 字节/组，`nfds=320`）；
* futex waiter 相对 syscall SP 的位置（本机 `SP-0x1d0`；waiter = bitmaps + 0x30）。

用仓库的 QEMU 模型与 host tests 验证几何后再上真机。

### 7.7 写路径检查

* **SELinux zero 写**：target `selinux_state`、value 0；zero/leaf 写时 `rb_erase` 的
  victim 必须是 **RED**（bit0=0），否则 rebalance 会遍历 fake parent。另有
  preserve-initialized（非零 child）变体。
* **Cred 写**：fake `cred` 页、`task->cred`/`real_cred`、`user_ns`、`init_cred`；
  子进程必须先验证 uid=0 再 exec broker；exec 前 SELinux 必须已经关闭。
* 保持"每次写都 fresh reclaim"的顺序：先 SELinux、后 cred；不要复用已经捕获的页做
  第二次写，除非重新 re-arm 所有 waiter/lock 字段并重新验证 color。

### 7.8 失败特征表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `[!] unsupported kernel` | build 不匹配 | 不要运行；按 7.2–7.6 适配 |
| `capture witness verdict=0`，`hit` 全 0 | witness 窗口/寄存器错、perf 受限、时序 | 复核偏移与 `perf_event_paranoid`；重试；试 `--perf-loops 20000` |
| 采样很久后 `complete=0` | 采样阶段未完成，witness 放弃 | 若未写内核可同 boot 重试，否则重启 |
| `W1 PASS`、`W2 FAIL` | 第二次 capture 抖动/回收状态 | **重启**后重试（脚本会提示） |
| split 崩溃/卡死 | 栈几何或 settle 不匹配、fake waiter 字段错 | 用精确 vmlinux + QEMU 复核；不要同 boot 重试 |
| cred 成功但没有 root shell | SELinux 未真正关闭、agent exec 被拦、client/agent 版本不匹配 | 查 `getenforce`；确认 agent/client 同一版本 |
| 连上但没有提示符 | stdin 不是 tty，或从非交互 `adb shell` 启动 | 在交互式 `adb shell` 里跑；或用 `--exec`/`--no-shell` |

### 7.9 重新构建与打包

* 工具链：Android NDK clang（静态），`-DGHOST_DEVICE_<TARGET>` profile；aarch64 主程序 + AArch32 helper（载体需要时）。
* 先跑 host/QEMU 测试；真机每次 boot 只尝试一次。
* 用 `make_oneclick.py` 重新生成单文件包（gzip+base64、成员顺序/mtime/uid/gid 固定），并更新 `SHA256SUMS`。
* 内嵌的 lab/helper/agent/client 任一变化都必须生成新的 bundle hash；bundle 的可信度不会高于其内嵌产物。

## 8. 校验下载

```bash
sha256sum -c SHA256SUMS
```

`ghostlock-kirkwood-oneclick.sh`：**14,426,154 字节**，
sha256 `a4968b9bb9fc451066e060d66739a2af5e05640827df8ddcd1ed46b32beb1150`。
bundle 是固定的 gzip+base64 payload；4 个内嵌产物 hash 写在 `SHA256SUMS` 里，解包后可复核：

```bash
# 设备上先 --extract-only：
sha256sum /data/local/tmp/.ghostlock-oneclick/*
```

## 9. 致谢与许可

本移植直接建立在公开安全研究之上，感谢：

* [NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia) — GhostLock/IonStack 原始研究（Apache-2.0）；
* [k-o-n-t-o-r/ghostlock-sabrina](https://github.com/k-o-n-t-o-r/ghostlock-sabrina) — Sabrina 参考实现；
* [R0rt1z2/GhostLock](https://github.com/R0rt1z2/GhostLock) — GhostLock 实现与 target profile；
* [isec-tugraz/KernelSnitch](https://github.com/isec-tugraz/KernelSnitch) — futex 时序侧信道（MIT）；
* TCL C855 / T653T01 移植（`ghostlock-tcl-c855`，Apache-2.0）— ARM32 `_newselect` 载体、安全门禁、SELinux-first 配方与 QEMU/真机验证方法；
* Android Common Kernel 与 Linux 内核 futex/rbtree 源码，以及公开的 CVE-2026-43499 记录。

许可：本仓库代码与文档采用 Apache-2.0；内嵌第三方组件保留各自许可。见
[`LICENSE`](LICENSE)、[`NOTICE.md`](NOTICE.md)、
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)、[`LICENSES/`](LICENSES/)。
未发布许可元数据的上游项目仍受其作者权利约束；致谢不授予额外权利。

## 10. FAQ

**能持久吗？** 不能。重启恢复 SELinux enforcing 和原凭据；锁定 bootloader + AVB green
下没有安全的持久 root。
**能在另一台 Google TV Streamer 上用吗？** 只有 `uname -r`（最好连完整 fingerprint）一致才行；
先跑 `check-kirkwood.sh`。
**为什么没有 su？** 我们只是切换 parked 子进程的 cred，并暴露一个 `AF_UNIX` pty shell；
没有持久守护进程。
**为什么第二阶段偶尔失败？** perf capture witness 有概率性；capture gate 宁可拒绝也不会盲写。
重启重试即可。
**能集成进 App 吗？** 当前形态需要交互式 ADB shell（或 `--exec`）；设计上故意不做持久服务。
**能发布吗？** 代码为 Apache-2.0 且带第三方声明；保留署名，不要发布固件 dump/密钥。
