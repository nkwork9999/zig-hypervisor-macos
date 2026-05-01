const std = @import("std");
const posix = std.posix;

const hv_return_t = i32;
const HV_SUCCESS: hv_return_t = 0;
const HV_MEMORY_READ: u64 = 1 << 0;
const HV_MEMORY_WRITE: u64 = 1 << 1;
const HV_MEMORY_EXEC: u64 = 1 << 2;

const HV_REG_X0: u32 = 0;
const HV_REG_PC: u32 = 31;
const HV_REG_CPSR: u32 = 34;
const HV_SYS_REG_VBAR_EL1: u16 = 0xC600;
const HV_SYS_REG_SP_EL0: u16 = 0xC208;
const HV_SYS_REG_SP_EL1: u16 = 0xE208;

const EC_DATA_ABORT: u32 = 0x24;
const EC_BRK: u32 = 0x3C;
const HV_EXIT_REASON_EXCEPTION: u32 = 1;

const HVExitInfo = extern struct {
    reason: u32,
    exception: extern struct {
        syndrome: u64,
        virtual_address: u64,
        physical_address: u64,
    },
};

extern "Hypervisor" fn hv_vm_create(config: ?*anyopaque) hv_return_t;
extern "Hypervisor" fn hv_vm_destroy() hv_return_t;
extern "Hypervisor" fn hv_vcpu_create(vcpu: *u64, exit: **HVExitInfo, config: ?*anyopaque) hv_return_t;
extern "Hypervisor" fn hv_vcpu_destroy(vcpu: u64) hv_return_t;
extern "Hypervisor" fn hv_vcpu_run(vcpu: u64) hv_return_t;
extern "Hypervisor" fn hv_vcpu_get_reg(vcpu: u64, reg: u32, value: *u64) hv_return_t;
extern "Hypervisor" fn hv_vcpu_set_reg(vcpu: u64, reg: u32, value: u64) hv_return_t;
extern "Hypervisor" fn hv_vcpu_set_sys_reg(vcpu: u64, reg: u16, value: u64) hv_return_t;
extern "Hypervisor" fn hv_vcpu_set_trap_debug_exceptions(vcpu: u64, enable: bool) hv_return_t;
extern "Hypervisor" fn hv_vm_map(addr: *anyopaque, ipa: u64, size: usize, flags: u64) hv_return_t;
extern "Hypervisor" fn hv_vm_unmap(ipa: u64, size: usize) hv_return_t;

const MEM_SIZE: usize = 0x200000;
const MEM_ADDR: u64 = 0x40000000;
const CODE_OFFSET: u64 = 0x1000;
const UART_BASE: u64 = 0x09000000;
const UART_DR: u64 = UART_BASE + 0x00;
const UART_FR: u64 = UART_BASE + 0x18;

var input_char: ?u8 = null;

fn writeInst(mem: []u8, o: *usize, inst: u32) void {
    mem[o.*] = @intCast(inst & 0xFF);
    mem[o.* + 1] = @intCast((inst >> 8) & 0xFF);
    mem[o.* + 2] = @intCast((inst >> 16) & 0xFF);
    mem[o.* + 3] = @intCast((inst >> 24) & 0xFF);
    o.* += 4;
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Demo C: UART入力 (エコーバック)\n", .{});
    std.debug.print("  キー入力 → ゲストが受信 → エコー\n", .{});
    std.debug.print("  'q' で終了\n", .{});
    std.debug.print("========================================\n\n", .{});

    if (hv_vm_create(null) != HV_SUCCESS) return;

    const guest_mem = std.heap.page_allocator.alloc(u8, MEM_SIZE) catch {
        _ = hv_vm_destroy();
        return;
    };
    defer std.heap.page_allocator.free(guest_mem);
    @memset(guest_mem, 0);

    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        guest_mem[i] = 0xE0;
        guest_mem[i + 1] = 0x1F;
        guest_mem[i + 2] = 0x20;
        guest_mem[i + 3] = 0xD4;
    }

    const code_off: usize = @intCast(CODE_OFFSET);
    var off: usize = code_off;

    writeInst(guest_mem, &off, 0xD2A12001);

    const banner = "Echo> ";
    for (banner) |ch| {
        writeInst(guest_mem, &off, 0xD2800002 | (@as(u32, ch) << 5));
        writeInst(guest_mem, &off, 0xF9000022);
    }

    const loop_addr = off;
    writeInst(guest_mem, &off, 0xB9401822);
    writeInst(guest_mem, &off, 0x37200042);
    writeInst(guest_mem, &off, 0xB9400020);
    writeInst(guest_mem, &off, 0x14000002);
    
    const wait_to_loop = @as(i32, @intCast(@as(i64, @intCast(loop_addr)) - @as(i64, @intCast(off)))) >> 2;
    writeInst(guest_mem, &off, 0x14000000 | @as(u32, @bitCast(wait_to_loop & 0x3FFFFFF)));
    
    writeInst(guest_mem, &off, 0x7101C41F);
    writeInst(guest_mem, &off, 0x540000C0);
    writeInst(guest_mem, &off, 0xF9000020);
    
    const proc_to_loop = @as(i32, @intCast(@as(i64, @intCast(loop_addr)) - @as(i64, @intCast(off)))) >> 2;
    writeInst(guest_mem, &off, 0x14000000 | @as(u32, @bitCast(proc_to_loop & 0x3FFFFFF)));

    const bye = "\nBye!\n";
    for (bye) |ch| {
        writeInst(guest_mem, &off, 0xD2800002 | (@as(u32, ch) << 5));
        writeInst(guest_mem, &off, 0xF9000022);
    }
    writeInst(guest_mem, &off, 0xD4200000);

    std.debug.print("[VMM] コード: {} bytes\n", .{off - code_off});

    if (hv_vm_map(@ptrCast(guest_mem.ptr), MEM_ADDR, MEM_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC) != HV_SUCCESS) {
        _ = hv_vm_destroy();
        return;
    }

    var vcpu: u64 = 0;
    var exit_info: *HVExitInfo = undefined;
    _ = hv_vcpu_create(&vcpu, &exit_info, null);
    _ = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5);
    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, MEM_ADDR + CODE_OFFSET);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL0, MEM_ADDR + 0x8000);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL1, MEM_ADDR + 0x10000);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_VBAR_EL1, MEM_ADDR);
    _ = hv_vcpu_set_trap_debug_exceptions(vcpu, true);

    const stdin_fd: posix.fd_t = 0;
    const original_termios = posix.tcgetattr(stdin_fd) catch {
        _ = hv_vm_destroy();
        return;
    };
    var raw = original_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
    defer posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    std.debug.print("[VMM] vCPU開始\n", .{});
    std.debug.print("--- ゲスト ---\n", .{});

    var running = true;
    var pc: u64 = 0;

    while (running) {
        var buf: [1]u8 = undefined;
        const n = posix.read(stdin_fd, &buf) catch 0;
        if (n > 0) input_char = buf[0];

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

                    if (ipa == UART_DR) {
                        if (wr) {
                            var v: u64 = 0;
                            _ = hv_vcpu_get_reg(vcpu, rg, &v);
                            std.debug.print("{c}", .{@as(u8, @intCast(v & 0xFF))});
                        } else {
                            const ch: u64 = if (input_char) |ic| ic else 0;
                            _ = hv_vcpu_set_reg(vcpu, rg, ch);
                            input_char = null;
                        }
                    } else if (ipa == UART_FR) {
                        const flags: u64 = if (input_char == null) 0x10 else 0x00;
                        _ = hv_vcpu_set_reg(vcpu, rg, flags);
                    }
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);
                },
                EC_BRK => {
                    std.debug.print("--- 終了 ---\n", .{});
                    running = false;
                },
                else => running = false,
            }
        } else running = false;
    }

    _ = hv_vcpu_destroy(vcpu);
    _ = hv_vm_unmap(MEM_ADDR, MEM_SIZE);
    _ = hv_vm_destroy();
    std.debug.print("Demo C 完了!\n", .{});
}
