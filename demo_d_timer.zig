const std = @import("std");

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
const HV_SYS_REG_CNTV_CTL_EL0: u16 = 0xDF19;
const HV_SYS_REG_CNTV_CVAL_EL0: u16 = 0xDF1A;

const EC_DATA_ABORT: u32 = 0x24;
const EC_BRK: u32 = 0x3C;
const HV_EXIT_REASON_EXCEPTION: u32 = 1;
const HV_EXIT_REASON_VTIMER_ACTIVATED: u32 = 2;

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
extern "Hypervisor" fn hv_vcpu_set_vtimer_mask(vcpu: u64, masked: bool) hv_return_t;
extern "Hypervisor" fn hv_vcpu_get_vtimer_offset(vcpu: u64, offset: *u64) hv_return_t;

extern "c" fn mach_absolute_time() u64;

const MEM_SIZE: usize = 0x200000;
const MEM_ADDR: u64 = 0x40000000;
const CODE_OFFSET: u64 = 0x1000;
const UART_BASE: u64 = 0x09000000;

const TIMER_DELAY: u64 = 12_000_000; // ~0.5s at 24MHz on Apple Silicon
const TICK_COUNT: u32 = 5;

fn writeInst(mem: []u8, off: *usize, inst: u32) void {
    mem[off.*] = @intCast(inst & 0xFF);
    mem[off.* + 1] = @intCast((inst >> 8) & 0xFF);
    mem[off.* + 2] = @intCast((inst >> 16) & 0xFF);
    mem[off.* + 3] = @intCast((inst >> 24) & 0xFF);
    off.* += 4;
}

fn emitUartString(mem: []u8, off: *usize, msg: []const u8) void {
    for (msg) |ch| {
        writeInst(mem, off, 0xD2800002 | (@as(u32, ch) << 5)); // mov x2, #ch
        writeInst(mem, off, 0xF9000022); // str x2, [x1]
    }
}

// VMM側から vTimer を N ticks 後に発火するようセットアップ
fn armTimer(vcpu: u64, vtimer_offset: u64, delay: u64) void {
    const now = mach_absolute_time();
    const cval = now + delay - vtimer_offset;
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_CNTV_CVAL_EL0, cval);
    _ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_CNTV_CTL_EL0, 1); // ENABLE=1, IMASK=0
    _ = hv_vcpu_set_vtimer_mask(vcpu, false);
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Demo D: vTimer (VMM側タイマー制御)\n", .{});
    std.debug.print("  Guest: b . で待機, VMMがタイマー発火で解除\n", .{});
    std.debug.print("  {} tick x ~0.5秒\n", .{TICK_COUNT});
    std.debug.print("========================================\n\n", .{});

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

    // 例外ベクタ (BRK pattern)
    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        guest_mem[i] = 0xE0;
        guest_mem[i + 1] = 0x1F;
        guest_mem[i + 2] = 0x20;
        guest_mem[i + 3] = 0xD4;
    }

    // ============== Guest Code ==============
    //
    // mov x1, #UART_BASE
    // print "Timer Demo\n"
    // mov x3, #TICK_COUNT
    //
    // tick_start:
    //   b .                  ← VMMがタイマー発火時にPC+=4
    //   print "Tick "
    //   x4 = (TICK_COUNT+1) - x3
    //   print digit(x4)
    //   print "\n"
    //   subs x3, x3, #1
    //   b.gt tick_start
    //
    // print "Done!\n"
    // brk #0

    const code_off: usize = @intCast(CODE_OFFSET);
    var c: usize = code_off;

    // mov x1, #0x0900, lsl #16
    writeInst(guest_mem, &c, 0xD2A12001);

    emitUartString(guest_mem, &c, "Timer Demo\n");

    // mov x3, #TICK_COUNT
    writeInst(guest_mem, &c, 0xD2800003 | (@as(u32, TICK_COUNT) << 5));

    // ---- tick_start ----
    const tick_start = c;
    const wait_addr_offset = c - code_off; // for logging

    // b .  (VMM will skip past this on timer fire)
    writeInst(guest_mem, &c, 0x14000000);

    // Print "Tick "
    emitUartString(guest_mem, &c, "Tick ");

    // Compute and print digit: x4 = (TICK_COUNT+1) - x3
    writeInst(guest_mem, &c, 0xD2800004 | (@as(u32, TICK_COUNT + 1) << 5)); // mov x4, #(TICK_COUNT+1)
    writeInst(guest_mem, &c, 0xCB030084); // sub x4, x4, x3
    writeInst(guest_mem, &c, 0x9100C082); // add x2, x4, #'0'
    writeInst(guest_mem, &c, 0xF9000022); // str x2, [x1]

    emitUartString(guest_mem, &c, "\n");

    // subs x3, x3, #1
    writeInst(guest_mem, &c, 0xF1000463);

    // b.gt tick_start
    const branch_offset = @as(i32, @intCast(@as(i64, @intCast(tick_start)) - @as(i64, @intCast(c)))) >> 2;
    const branch_inst: u32 = 0x5400000C | (@as(u32, @bitCast(branch_offset & 0x7FFFF)) << 5);
    writeInst(guest_mem, &c, branch_inst);

    emitUartString(guest_mem, &c, "Done!\n");

    // brk #0
    writeInst(guest_mem, &c, 0xD4200000);

    std.debug.print("[VMM] コード: {} bytes\n", .{c - code_off});
    std.debug.print("[VMM] 待機アドレス (b .): 0x{X}\n", .{MEM_ADDR + wait_addr_offset});

    // ============== VM Setup ==============

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

    // vTimer offset を取得 (CNTVCT_EL0 = mach_absolute_time() - offset)
    var vtimer_offset: u64 = 0;
    _ = hv_vcpu_get_vtimer_offset(vcpu, &vtimer_offset);
    std.debug.print("[VMM] vTimer offset: 0x{X}\n", .{vtimer_offset});

    // 初回タイマーを設定
    armTimer(vcpu, vtimer_offset, TIMER_DELAY);

    std.debug.print("[VMM] vCPU開始 (VMM側タイマー制御)\n", .{});
    std.debug.print("--- ゲスト出力 ---\n", .{});

    // ============== Execution Loop ==============

    var running = true;
    var pc: u64 = 0;
    var timer_count: u32 = 0;

    while (running) {
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
                    if (ipa >= UART_BASE and ipa < UART_BASE + 0x1000 and wr) {
                        var v: u64 = 0;
                        _ = hv_vcpu_get_reg(vcpu, rg, &v);
                        std.debug.print("{c}", .{@as(u8, @intCast(v & 0xFF))});
                    }
                    _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);
                },
                EC_BRK => {
                    std.debug.print("--- 終了 ---\n", .{});
                    running = false;
                },
                else => {
                    std.debug.print("\n[VMM] 例外 EC=0x{X} PC=0x{X}\n", .{ ec, pc });
                    running = false;
                },
            }
        } else if (exit_info.reason == HV_EXIT_REASON_VTIMER_ACTIVATED) {
            timer_count += 1;
            std.debug.print("\n[VMM] vTimer #{} 発火 (PC=0x{X})\n", .{ timer_count, pc });

            // b . を抜ける
            _ = hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4);

            // 次のティック用にタイマー再武装 (mask も解除される)
            armTimer(vcpu, vtimer_offset, TIMER_DELAY);
        } else {
            std.debug.print("[VMM] 不明な終了理由: {}\n", .{exit_info.reason});
            running = false;
        }
    }

    _ = hv_vcpu_destroy(vcpu);
    _ = hv_vm_unmap(MEM_ADDR, MEM_SIZE);
    _ = hv_vm_destroy();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Demo D 完了! (タイマー発火: {} 回)\n", .{timer_count});
    std.debug.print("========================================\n", .{});
}
