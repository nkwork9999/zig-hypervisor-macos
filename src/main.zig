const std = @import("std");
const posix = std.posix;
const hv = @import("hv.zig");
const dtb = @import("dtb.zig");
const gic_mod = @import("gic.zig");
const pl011_mod = @import("pl011.zig");

// 別スレッド: 33ms ごとに guest framebuffer を viewer の stdin (パイプ) に送る
const FbDumperArgs = struct {
    guest_mem: []u8,
    fb_offset: usize,
    fb_size: usize,
    pipe_fd: std.posix.fd_t,
};

fn fbDumperThread(args: FbDumperArgs) void {
    const fb = args.guest_mem[args.fb_offset..][0..args.fb_size];
    while (true) {
        std.posix.nanosleep(0, 33_000_000); // ~30 fps
        var written: usize = 0;
        while (written < fb.len) {
            const n = std.posix.write(args.pipe_fd, fb[written..]) catch return;
            if (n == 0) return;
            written += n;
        }
    }
}

// hv 名前空間のショートカット
const HV_SUCCESS = hv.HV_SUCCESS;
const HV_REG_X0 = hv.HV_REG_X0;
const HV_REG_PC = hv.HV_REG_PC;
const HV_REG_CPSR = hv.HV_REG_CPSR;
const HV_SYS_REG_VBAR_EL1 = hv.HV_SYS_REG_VBAR_EL1;
const HV_SYS_REG_SP_EL0 = hv.HV_SYS_REG_SP_EL0;
const HV_SYS_REG_SP_EL1 = hv.HV_SYS_REG_SP_EL1;
const HV_SYS_REG_CNTV_CTL_EL0 = hv.HV_SYS_REG_CNTV_CTL_EL0;
const HV_SYS_REG_CNTV_CVAL_EL0 = hv.HV_SYS_REG_CNTV_CVAL_EL0;
const HV_MEMORY_READ = hv.HV_MEMORY_READ;
const HV_MEMORY_WRITE = hv.HV_MEMORY_WRITE;
const HV_MEMORY_EXEC = hv.HV_MEMORY_EXEC;
const EC_HVC = hv.EC_HVC;
const EC_DATA_ABORT = hv.EC_DATA_ABORT;
const EC_BRK = hv.EC_BRK;
const HV_EXIT_REASON_EXCEPTION = hv.HV_EXIT_REASON_EXCEPTION;
const HV_EXIT_REASON_VTIMER_ACTIVATED = hv.HV_EXIT_REASON_VTIMER_ACTIVATED;
const HV_INTERRUPT_TYPE_IRQ = hv.HV_INTERRUPT_TYPE_IRQ;
const hv_vm_create = hv.hv_vm_create;
const hv_vm_destroy = hv.hv_vm_destroy;
const hv_vm_map = hv.hv_vm_map;
const hv_vm_unmap = hv.hv_vm_unmap;
const hv_vcpu_create = hv.hv_vcpu_create;
const hv_vcpu_destroy = hv.hv_vcpu_destroy;
const hv_vcpu_run = hv.hv_vcpu_run;
const hv_vcpu_get_reg = hv.hv_vcpu_get_reg;
const hv_vcpu_set_reg = hv.hv_vcpu_set_reg;
const hv_vcpu_set_sys_reg = hv.hv_vcpu_set_sys_reg;
const hv_vcpu_set_trap_debug_exceptions = hv.hv_vcpu_set_trap_debug_exceptions;
const hv_vcpu_set_vtimer_mask = hv.hv_vcpu_set_vtimer_mask;
const hv_vcpu_get_vtimer_offset = hv.hv_vcpu_get_vtimer_offset;
const hv_vcpu_set_pending_interrupt = hv.hv_vcpu_set_pending_interrupt;
const mach_absolute_time = hv.mach_absolute_time;
const HVExitInfo = hv.HVExitInfo;

fn uart_out(c: u8) void {
    std.debug.print("{c}", .{c});
}


// PSCI function IDs (SMC32 variant, prefix 0x84)
const PSCI_VERSION: u64 = 0x84000000;
const PSCI_CPU_OFF: u64 = 0x84000002;
const PSCI_SYSTEM_OFF: u64 = 0x84000008;
const PSCI_SYSTEM_RESET: u64 = 0x84000009;
const PSCI_FEATURES: u64 = 0x8400000A;

const PSCI_RET_SUCCESS: u64 = 0;
const PSCI_RET_NOT_SUPPORTED: u64 = @bitCast(@as(i64, -1));
const PSCI_VERSION_1_1: u64 = 0x00010001;

const MEM_SIZE: usize = 0x20000000; // 512MB
const MEM_ADDR: u64 = 0x40000000;
const UART_BASE: u64 = 0x09000000;
const TIMER_SLEEP_ADDR: u64 = 0x09001000;
const GIC_DIST_BASE: u64 = 0x08000000; // GICv2 Distributor
const GIC_CPU_BASE: u64 = 0x08010000; // GICv2 CPU Interface
const DTB_LOAD_ADDR: u64 = 0x44000000;
const INITRD_LOAD_ADDR: u64 = 0x45000000;
// simple-framebuffer (1024x768 BGRA = 3MB)
const FB_BASE: u64 = 0x50000000;
const FB_WIDTH: u32 = 1024;
const FB_HEIGHT: u32 = 768;
const FB_BYTES_PER_PIXEL: u32 = 4;
const FB_SIZE: u64 = @as(u64, FB_WIDTH) * FB_HEIGHT * FB_BYTES_PER_PIXEL;

// ============== ELF Loader ==============

const ELF_MAGIC = "\x7fELF";

const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const PT_LOAD: u32 = 1;

const ElfLoadResult = struct {
    entry_point: u64,
    loaded: bool,
};

fn loadElf(elf_data: []const u8, guest_mem: []u8, mem_base: u64) ElfLoadResult {
    // マジック確認
    if (elf_data.len < @sizeOf(Elf64Header)) {
        std.debug.print("[ELF] ファイルが小さすぎる\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }

    if (!std.mem.eql(u8, elf_data[0..4], ELF_MAGIC)) {
        std.debug.print("[ELF] 無効なマジック\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }

    // ELFヘッダー解析
    const header: *const Elf64Header = @ptrCast(@alignCast(elf_data.ptr));

    // AArch64確認 (0xB7 = EM_AARCH64)
    if (header.e_machine != 0xB7) {
        std.debug.print("[ELF] 非AArch64バイナリ: 0x{X}\n", .{header.e_machine});
        return .{ .entry_point = 0, .loaded = false };
    }

    std.debug.print("[ELF] エントリポイント: 0x{X}\n", .{header.e_entry});
    std.debug.print("[ELF] Program Headers: {} 個\n", .{header.e_phnum});

    // プログラムヘッダー処理
    var i: u16 = 0;
    while (i < header.e_phnum) : (i += 1) {
        const ph_offset = header.e_phoff + i * header.e_phentsize;
        if (ph_offset + @sizeOf(Elf64Phdr) > elf_data.len) break;

        const phdr: *const Elf64Phdr = @ptrCast(@alignCast(elf_data.ptr + ph_offset));

        if (phdr.p_type != PT_LOAD) continue;

        std.debug.print("[ELF] LOAD: vaddr=0x{X} filesz={} memsz={}\n", .{
            phdr.p_vaddr, phdr.p_filesz, phdr.p_memsz
        });

        // ゲストメモリにコピー
        const dest_offset = phdr.p_vaddr - mem_base;
        if (dest_offset + phdr.p_filesz > guest_mem.len) {
            std.debug.print("[ELF] メモリ範囲外\n", .{});
            continue;
        }

        const src = elf_data[phdr.p_offset..][0..phdr.p_filesz];
        const dest = guest_mem[dest_offset..][0..phdr.p_filesz];
        @memcpy(dest, src);

        // BSSゼロクリア
        if (phdr.p_memsz > phdr.p_filesz) {
            const bss_size = phdr.p_memsz - phdr.p_filesz;
            const bss_start = dest_offset + phdr.p_filesz;
            if (bss_start + bss_size <= guest_mem.len) {
                @memset(guest_mem[bss_start..][0..bss_size], 0);
            }
        }
    }

    return .{ .entry_point = header.e_entry, .loaded = true };
}

// ============== ARM64 Linux Image Loader ==============
// Image header (64 bytes):
//   [0..7]   code0+code1 (executable, usually `b primary_entry`)
//   [8..15]  text_offset (u64 LE)
//   [16..23] image_size  (u64 LE)
//   [24..31] flags       (u64 LE)
//   [32..55] reserved
//   [56..59] magic = 0x644D5241 ("ARM\x64" LE)
//   [60..63] reserved
const ARM64_IMAGE_MAGIC: u32 = 0x644D5241;

const ImageLoadResult = struct {
    entry_point: u64,
    loaded: bool,
};

fn loadImage(image_data: []const u8, guest_mem: []u8, mem_base: u64) ImageLoadResult {
    if (image_data.len < 64) {
        std.debug.print("[Image] ヘッダ不足\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }
    const magic = std.mem.readInt(u32, image_data[56..60], .little);
    if (magic != ARM64_IMAGE_MAGIC) {
        return .{ .entry_point = 0, .loaded = false };
    }
    const text_offset = std.mem.readInt(u64, image_data[8..16], .little);
    const image_size = std.mem.readInt(u64, image_data[16..24], .little);
    const flags = std.mem.readInt(u64, image_data[24..32], .little);
    std.debug.print("[Image] ARM64 magic OK\n", .{});
    std.debug.print("[Image] text_offset=0x{X} image_size=0x{X} flags=0x{X}\n", .{ text_offset, image_size, flags });

    const dest_offset = text_offset;
    if (dest_offset + image_data.len > guest_mem.len) {
        std.debug.print("[Image] メモリ範囲外\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }
    @memcpy(guest_mem[dest_offset..][0..image_data.len], image_data);
    return .{ .entry_point = mem_base + dest_offset, .loaded = true };
}

// ELFかImageかを判別してロード
fn loadKernel(data: []const u8, guest_mem: []u8, mem_base: u64) ElfLoadResult {
    // ELFマジック確認
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], ELF_MAGIC)) {
        return loadElf(data, guest_mem, mem_base);
    }
    // Imageフォーマット試行
    const img = loadImage(data, guest_mem, mem_base);
    return .{ .entry_point = img.entry_point, .loaded = img.loaded };
}

// ============== Main ==============

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  ZigVM - ELF Kernel Loader\n", .{});
    std.debug.print("========================================\n\n", .{});

    // カーネル読み込み (引数で指定、なければデフォルト)
    const args = std.process.argsAlloc(std.heap.page_allocator) catch {
        std.debug.print("[VMM] argsAlloc 失敗\n", .{});
        return;
    };
    defer std.process.argsFree(std.heap.page_allocator, args);
    const kernel_path = if (args.len >= 2) args[1] else "../202601zigos/zig-out/bin/kernel";
    const initrd_path: ?[]const u8 = if (args.len >= 3) args[2] else null;
    std.debug.print("[VMM] カーネルパス: {s}\n", .{kernel_path});
    if (initrd_path) |p| std.debug.print("[VMM] initramfs: {s}\n", .{p});
    const kernel_file = std.fs.cwd().openFile(kernel_path, .{}) catch |err| {
        std.debug.print("[VMM] カーネル読み込み失敗: {s}\n", .{kernel_path});
        std.debug.print("[VMM] エラー: {}\n", .{err});
        return;
    };
    defer kernel_file.close();

    const kernel_data = kernel_file.readToEndAlloc(std.heap.page_allocator, 64 * 1024 * 1024) catch {
        std.debug.print("[VMM] カーネル読み込み失敗\n", .{});
        return;
    };
    defer std.heap.page_allocator.free(kernel_data);
    std.debug.print("[VMM] カーネルファイル: {} bytes\n", .{kernel_data.len});

    // VM作成
    if (hv_vm_create(null) != HV_SUCCESS) {
        std.debug.print("[VMM] VM作成失敗\n", .{});
        return;
    }

    const guest_mem = std.heap.page_allocator.alloc(u8, MEM_SIZE) catch {
        _ = hv_vm_destroy();
        return;
    };
    defer std.heap.page_allocator.free(guest_mem);
    @memset(guest_mem, 0);

    // 例外ベクタ
    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        guest_mem[i] = 0xE0;
        guest_mem[i + 1] = 0x1F;
        guest_mem[i + 2] = 0x20;
        guest_mem[i + 3] = 0xD4;
    }

    // ELF or Image ロード
    const elf_result = loadKernel(kernel_data, guest_mem, MEM_ADDR);
    if (!elf_result.loaded) {
        std.debug.print("[VMM] カーネルロード失敗 (ELF/Image どちらでもない)\n", .{});
        _ = hv_vm_destroy();
        return;
    }

    std.debug.print("[VMM] ロード完了\n", .{});

    // initramfs ロード
    var initrd_size: u64 = 0;
    if (initrd_path) |p| {
        const initrd_file = std.fs.cwd().openFile(p, .{}) catch |err| {
            std.debug.print("[VMM] initramfs open失敗: {}\n", .{err});
            _ = hv_vm_destroy();
            return;
        };
        defer initrd_file.close();
        const initrd_data = initrd_file.readToEndAlloc(std.heap.page_allocator, 64 * 1024 * 1024) catch {
            std.debug.print("[VMM] initramfs読み込み失敗\n", .{});
            _ = hv_vm_destroy();
            return;
        };
        defer std.heap.page_allocator.free(initrd_data);
        const initrd_offset = INITRD_LOAD_ADDR - MEM_ADDR;
        if (initrd_offset + initrd_data.len > guest_mem.len) {
            std.debug.print("[VMM] initramfsがメモリ範囲外\n", .{});
            _ = hv_vm_destroy();
            return;
        }
        @memcpy(guest_mem[initrd_offset..][0..initrd_data.len], initrd_data);
        initrd_size = initrd_data.len;
        std.debug.print("[VMM] initramfs: {} bytes @ 0x{X}\n", .{ initrd_size, INITRD_LOAD_ADDR });
    }

    // DTB 生成 & ゲストメモリにコピー
    // FB 領域はLinuxのRAMの外 (0x50000000) に置く。memは0x40000000-0x50000000の256MB に縮める
    const linux_ram_size: u64 = FB_BASE - MEM_ADDR; // 256MB
    const dtb_bytes = dtb.buildZigVmDtb(std.heap.page_allocator, .{
        .mem_base = MEM_ADDR,
        .mem_size = linux_ram_size,
        .uart_base = UART_BASE,
        .gic_dist_base = GIC_DIST_BASE,
        .gic_cpu_base = GIC_CPU_BASE,
        .bootargs = "console=ttyAMA0 earlycon=pl011,0x9000000 single usbdelay=1 fbcon=off",
        .initrd_start = if (initrd_size > 0) INITRD_LOAD_ADDR else 0,
        .initrd_end = if (initrd_size > 0) INITRD_LOAD_ADDR + initrd_size else 0,
        .fb_base = FB_BASE,
        .fb_width = FB_WIDTH,
        .fb_height = FB_HEIGHT,
    }) catch {
        std.debug.print("[VMM] DTB生成失敗\n", .{});
        _ = hv_vm_destroy();
        return;
    };
    defer std.heap.page_allocator.free(dtb_bytes);

    const dtb_offset = DTB_LOAD_ADDR - MEM_ADDR;
    if (dtb_offset + dtb_bytes.len > guest_mem.len) {
        std.debug.print("[VMM] DTB配置アドレスがメモリ範囲外\n", .{});
        _ = hv_vm_destroy();
        return;
    }
    @memcpy(guest_mem[dtb_offset..][0..dtb_bytes.len], dtb_bytes);
    std.debug.print("[VMM] DTB: {} bytes @ 0x{X}\n", .{ dtb_bytes.len, DTB_LOAD_ADDR });

    // メモリマップ
    if (hv_vm_map(@ptrCast(guest_mem.ptr), MEM_ADDR, MEM_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC) != HV_SUCCESS) {
        _ = hv_vm_destroy();
        return;
    }

    // vCPU作成
    var vcpu: u64 = 0;
    var exit_info: *HVExitInfo = undefined;
    _ = hv_vcpu_create(&vcpu, &exit_info, null);
    _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5);
    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, elf_result.entry_point);
    // Linux boot protocol: x0 = DTB address, x1..x3 = 0 (reserved)
    _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, DTB_LOAD_ADDR);
    var rn: u32 = 1;
    while (rn <= 7) : (rn += 1) {
        _ = hv_vcpu_set_reg(vcpu, rn, 0);
    }
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL0, MEM_ADDR + 0x8000);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL1, MEM_ADDR + 0x10000);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_VBAR_EL1, MEM_ADDR);
    _ = hv_vcpu_set_trap_debug_exceptions(vcpu, true);

    // vTimer セットアップ
    var vtimer_offset: u64 = 0;
    _ = hv_vcpu_get_vtimer_offset(vcpu, &vtimer_offset);

    // IRQ/FIQ pending をクリア。vTimerはLinuxが使うのでunmask。
    _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, false);
    _ = hv_vcpu_set_vtimer_mask(vcpu, false);

    // GIC 状態
    var gic: gic_mod.Gic = .{};
    const VTIMER_IRQ: u32 = 27; // PPI 11 = IRQ ID 27
    const PL011_IRQ: u32 = 33; // DTBの interrupts=<0 1 4> → SPI ID 1 = GIC IRQ 32+1

    // PL011 UART 状態
    var pl011: pl011_mod.Pl011 = pl011_mod.Pl011.init(uart_out);

    // ホスト stdin を non-blocking化 (tty/pipe両対応で PL011 RX に流す)
    const stdin_fd: posix.fd_t = 0;
    const O_NONBLOCK: u32 = 0x0004; // Darwin
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const orig_flags = std.c.fcntl(stdin_fd, F_GETFL, @as(i32, 0));
    _ = std.c.fcntl(stdin_fd, F_SETFL, orig_flags | @as(i32, @intCast(O_NONBLOCK)));

    var orig_termios: posix.termios = undefined;
    const have_tty = posix.isatty(stdin_fd);
    if (have_tty) {
        orig_termios = posix.tcgetattr(stdin_fd) catch undefined;
        var raw = orig_termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
    }
    defer {
        if (have_tty) posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
        _ = std.c.fcntl(stdin_fd, F_SETFL, orig_flags);
    }

    std.debug.print("[VMM] PC=0x{X}\n", .{elf_result.entry_point});
    std.debug.print("[VMM] vTimer offset: 0x{X}\n", .{vtimer_offset});
    std.debug.print("[VMM] vCPU開始\n", .{});
    std.debug.print("--- MyOS ---\n", .{});

    // zigvm-viewer 子プロセス起動 (環境変数 ZIGVM_DISPLAY=1)
    const display_enabled = std.posix.getenv("ZIGVM_DISPLAY") != null;
    var fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer fb_arena.deinit();
    var viewer_keys_fd: posix.fd_t = -1;
    if (display_enabled) {
        var wbuf: [16]u8 = undefined;
        var hbuf: [16]u8 = undefined;
        const w_str = std.fmt.bufPrint(&wbuf, "{}", .{FB_WIDTH}) catch unreachable;
        const h_str = std.fmt.bufPrint(&hbuf, "{}", .{FB_HEIGHT}) catch unreachable;
        // viewer 実行ファイルは zigvm と同じディレクトリにある想定
        var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_path_buf) catch "./zig-out/bin/zigvm";
        const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
        const viewer_path = std.fmt.allocPrint(fb_arena.allocator(), "{s}/zigvm-viewer", .{exe_dir}) catch "./zig-out/bin/zigvm-viewer";
        var child = std.process.Child.init(&.{ viewer_path, w_str, h_str }, fb_arena.allocator());
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |e| {
            std.debug.print("[VMM] zigvm-viewer起動失敗: {}\n", .{e});
        };
        if (child.stdin) |stdin| if (child.stdout) |stdout| {
            // viewer の stdout (key events) を non-blocking に
            const F_GETFL_p: i32 = 3;
            const F_SETFL_p: i32 = 4;
            const O_NONBLOCK_p: u32 = 0x0004;
            const flags2 = std.c.fcntl(stdout.handle, F_GETFL_p, @as(i32, 0));
            _ = std.c.fcntl(stdout.handle, F_SETFL_p, flags2 | @as(i32, @intCast(O_NONBLOCK_p)));
            viewer_keys_fd = stdout.handle;

            const fb_args: FbDumperArgs = .{
                .guest_mem = guest_mem,
                .fb_offset = @intCast(FB_BASE - MEM_ADDR),
                .fb_size = @intCast(FB_SIZE),
                .pipe_fd = stdin.handle,
            };
            const t = std.Thread.spawn(.{}, fbDumperThread, .{fb_args}) catch |e| {
                std.debug.print("[VMM] fb dumper thread起動失敗: {}\n", .{e});
                return;
            };
            t.detach();
            std.debug.print("[VMM] zigvm-viewer 起動 ({}x{}, 30fps)\n", .{ FB_WIDTH, FB_HEIGHT });
        };
    }

    // 実行ループ
    var running = true;
    var pc: u64 = 0;
    var timer_fires: u32 = 0;

    while (running) {
        // 1) ホスト stdin → PL011 RX 配線 (tty/pipe両対応)
        var sbuf: [16]u8 = undefined;
        const n = posix.read(stdin_fd, &sbuf) catch 0;
        if (n > 0) {
            for (sbuf[0..n]) |c| pl011.pushRxChar(c);
        }
        // 1b) viewer (SDL) からのキー入力を pl011 RX へ
        if (viewer_keys_fd >= 0) {
            var kbuf: [16]u8 = undefined;
            const kn = posix.read(viewer_keys_fd, &kbuf) catch 0;
            if (kn > 0) {
                for (kbuf[0..kn]) |c| pl011.pushRxChar(c);
            }
        }
        // 2) PL011 RX IRQ pending → GIC SPI 1 配信 (毎ループでチェック)
        if (pl011.rxIrqPending() and gic.assertIrq(PL011_IRQ)) {
            _ = hv_vcpu_set_pending_interrupt(vcpu, hv.HV_INTERRUPT_TYPE_IRQ, true);
        }

        if (hv_vcpu_run(vcpu) != HV_SUCCESS) break;
        _ = hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc);

        if (exit_info.reason == HV_EXIT_REASON_EXCEPTION) {
            const syn = exit_info.exception.syndrome;
            const ec = @as(u32, @intCast((syn >> 26) & 0x3F));
            const ipa = exit_info.exception.physical_address;

            switch (ec) {
                EC_DATA_ABORT => {
                    const wr = ((syn >> 6) & 1) == 1;
                    const rg = @as(u32, @intCast((syn >> 16) & 0x1F));

                    if (ipa >= UART_BASE and ipa < UART_BASE + 0x1000) {
                        const off: u32 = @intCast(ipa - UART_BASE);
                        if (wr) {
                            var v: u64 = 0;
                            _ = hv_vcpu_get_reg(vcpu, rg, &v);
                            pl011.write(off, @intCast(v & 0xFFFF_FFFF));
                        } else {
                            const v = pl011.read(off);
                            _ = hv_vcpu_set_reg(vcpu, rg, v);
                        }
                    } else if (ipa >= GIC_DIST_BASE and ipa < GIC_DIST_BASE + 0x10000) {
                        // GICD MMIO
                        const off: u32 = @intCast(ipa - GIC_DIST_BASE);
                        if (wr) {
                            var v: u64 = 0;
                            _ = hv_vcpu_get_reg(vcpu, rg, &v);
                            gic.distWrite(off, @intCast(v & 0xFFFF_FFFF));
                        } else {
                            const v = gic.distRead(off);
                            _ = hv_vcpu_set_reg(vcpu, rg, v);
                        }
                    } else if (ipa >= GIC_CPU_BASE and ipa < GIC_CPU_BASE + 0x10000) {
                        // GICC MMIO
                        const off: u32 = @intCast(ipa - GIC_CPU_BASE);
                        if (wr) {
                            var v: u64 = 0;
                            _ = hv_vcpu_get_reg(vcpu, rg, &v);
                            const irq_num: u32 = @intCast(v & 0x3FF);
                            gic.cpuWrite(off, @intCast(v & 0xFFFF_FFFF));
                            // EOIR for vTimer IRQ → unmask vtimer (Apple Hypervisor自動マスク解除)
                            if (off == 0x010 and irq_num == VTIMER_IRQ) {
                                _ = hv_vcpu_set_vtimer_mask(vcpu, false);
                            }
                        } else {
                            const v = gic.cpuRead(off);
                            _ = hv_vcpu_set_reg(vcpu, rg, v);
                        }
                        // GIC状態変化後はIRQライン再評価
                        const should = gic.shouldDeliver();
                        _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, should);
                    } else if (ipa == TIMER_SLEEP_ADDR and wr) {
                        // TIMER_SLEEP書き込み: vTimer武装 (GIC通過のIRQに変更)
                        var delay: u64 = 0;
                        _ = hv_vcpu_get_reg(vcpu, rg, &delay);
                        const now = mach_absolute_time();
                        const cval = now + delay - vtimer_offset;
                        _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_CNTV_CVAL_EL0, cval);
                        _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_CNTV_CTL_EL0, 1);
                        _ = hv_vcpu_set_vtimer_mask(vcpu, false);
                    }
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);
                },
                EC_HVC => {
                    // PSCI ハンドリング (x0=function ID)
                    var fn_id: u64 = 0;
                    _ = hv_vcpu_get_reg(vcpu, HV_REG_X0, &fn_id);
                    var ret: u64 = PSCI_RET_NOT_SUPPORTED;
                    var should_stop = false;

                    if (fn_id == PSCI_VERSION) {
                        ret = PSCI_VERSION_1_1;
                    } else if (fn_id == PSCI_FEATURES) {
                        // Check if a specific function is supported (x1 = fn_id)
                        var requested: u64 = 0;
                        _ = hv_vcpu_get_reg(vcpu, 1, &requested); // X1
                        ret = switch (requested) {
                            PSCI_VERSION, PSCI_SYSTEM_OFF, PSCI_SYSTEM_RESET, PSCI_FEATURES => PSCI_RET_SUCCESS,
                            else => PSCI_RET_NOT_SUPPORTED,
                        };
                    } else if (fn_id == PSCI_SYSTEM_OFF) {
                        std.debug.print("\n[VMM] PSCI: SYSTEM_OFF\n", .{});
                        should_stop = true;
                    } else if (fn_id == PSCI_SYSTEM_RESET) {
                        std.debug.print("\n[VMM] PSCI: SYSTEM_RESET (停止扱い)\n", .{});
                        should_stop = true;
                    } else {
                        std.debug.print("\n[VMM] PSCI: 未対応 fn_id=0x{X}\n", .{fn_id});
                    }

                    _ = hv_vcpu_set_reg(vcpu, HV_REG_X0, ret);
                    // HVC は ELR_EL2 が既に PC+4 に設定されている。PC を上書きしない。
                    if (should_stop) running = false;
                },
                EC_BRK => {
                    std.debug.print("------------\n", .{});
                    std.debug.print("[VMM] MyOS終了 (timer発火: {} 回, PC=0x{X})\n", .{ timer_fires, pc });
                    running = false;
                },
                0x01 => {
                    // WFI/WFE trap — host CPUを少しyield (1ms)、次のイベント待ち
                    std.posix.nanosleep(0, 1_000_000);
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);
                },
                0x18 => {
                    // MSR/MRS trap: ISS を解析
                    const iss = syn & 0xFFFFFF;
                    const op0: u32 = @intCast((iss >> 20) & 0x3);
                    const op2: u32 = @intCast((iss >> 17) & 0x7);
                    const op1: u32 = @intCast((iss >> 14) & 0x7);
                    const crn: u32 = @intCast((iss >> 10) & 0xF);
                    const rt: u32 = @intCast((iss >> 5) & 0x1F);
                    const crm: u32 = @intCast((iss >> 1) & 0xF);
                    const is_read = (iss & 1) == 1;
                    std.debug.print("\n[VMM] sysreg trap: op0={} op1={} CRn={} CRm={} op2={} Rt=x{} {s} PC=0x{X}\n", .{
                        op0, op1, crn, crm, op2, rt,
                        if (is_read) "READ" else "WRITE",
                        pc,
                    });
                    if (is_read) {
                        _ = hv_vcpu_set_reg(vcpu, rt, 0);
                    }
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);
                },
                else => {
                    std.debug.print("\n[VMM] 例外 EC=0x{X} PC=0x{X}\n", .{ec, pc});
                    running = false;
                },
            }
        } else if (exit_info.reason == HV_EXIT_REASON_VTIMER_ACTIVATED) {
            // vTimer発火 → GIC内部でIRQ 27をペンディング → 配信可なら set_pending_interrupt
            timer_fires += 1;
            _ = hv_vcpu_set_vtimer_mask(vcpu, true);
            if (gic.assertIrq(VTIMER_IRQ)) {
                _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true);
            }
        } else {
            running = false;
        }
    }

    _ = hv_vcpu_destroy(vcpu);
    _ = hv_vm_unmap(MEM_ADDR, MEM_SIZE);
    _ = hv_vm_destroy();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  ZigVM Complete!\n", .{});
    std.debug.print("========================================\n", .{});
}