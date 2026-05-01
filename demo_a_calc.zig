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

fn writeInst(mem: []u8, off: *usize, inst: u32) void {
    mem[off.*] = @intCast(inst & 0xFF);
    mem[off.* + 1] = @intCast((inst >> 8) & 0xFF);
    mem[off.* + 2] = @intCast((inst >> 16) & 0xFF);
    mem[off.* + 3] = @intCast((inst >> 24) & 0xFF);
    off.* += 4;
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Demo A: 計算結果をUART経由で表示\n", .{});
    std.debug.print("  ゲスト: 1+2+3+...+10 を計算\n", .{});
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

    // 例外ベクタ
    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        guest_mem[i] = 0xE0;
        guest_mem[i + 1] = 0x1F;
        guest_mem[i + 2] = 0x20;
        guest_mem[i + 3] = 0xD4;
    }

    const code_off: usize = @intCast(CODE_OFFSET);
    var c: usize = code_off;

    // mov x1, #0x0900, lsl #16
    writeInst(guest_mem, &c, 0xD2A12001);
    
    // mov x0, #0
    writeInst(guest_mem, &c, 0xD2800000);

    // add x0, x0, #1 ~ #10
    writeInst(guest_mem, &c, 0x91000400);
    writeInst(guest_mem, &c, 0x91000800);
    writeInst(guest_mem, &c, 0x91000C00);
    writeInst(guest_mem, &c, 0x91001000);
    writeInst(guest_mem, &c, 0x91001400);
    writeInst(guest_mem, &c, 0x91001800);
    writeInst(guest_mem, &c, 0x91001C00);
    writeInst(guest_mem, &c, 0x91002000);
    writeInst(guest_mem, &c, 0x91002400);
    writeInst(guest_mem, &c, 0x91002800);

    // "Result: "を出力
    const msg = "Result: ";
    for (msg) |ch| {
        writeInst(guest_mem, &c, 0xD2800002 | (@as(u32, ch) << 5)); // mov x2, #ch
        writeInst(guest_mem, &c, 0xF9000022); // str x2, [x1]
    }

    // x0 = 55 を2桁の数字として出力
    // mov x3, #10
    writeInst(guest_mem, &c, 0xD2800143);
    
    // udiv x4, x0, x3  (x4 = 55/10 = 5)
    writeInst(guest_mem, &c, 0x9AC30804);
    
    // mul x5, x4, x3   (x5 = 5*10 = 50)
    writeInst(guest_mem, &c, 0x9B037C85);
    
    // sub x5, x0, x5   (x5 = 55-50 = 5)
    writeInst(guest_mem, &c, 0xCB050005);
    
    // add x4, x4, #'0' (x4 = 5 + 48 = '5')
    writeInst(guest_mem, &c, 0x9100C084);
    
    // str x4, [x1]
    writeInst(guest_mem, &c, 0xF9000024);
    
    // add x5, x5, #'0' (x5 = 5 + 48 = '5')
    writeInst(guest_mem, &c, 0x9100C0A5);
    
    // str x5, [x1]
    writeInst(guest_mem, &c, 0xF9000025);

    // '\n' 出力
    writeInst(guest_mem, &c, 0xD2800142); // mov x2, #'\n'
    writeInst(guest_mem, &c, 0xF9000022); // str x2, [x1]

    // brk #0
    writeInst(guest_mem, &c, 0xD4200000);

    std.debug.print("[VMM] コード: {} bytes\n", .{c - code_off});

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

    std.debug.print("[VMM] vCPU開始\n", .{});
    std.debug.print("--- ゲスト出力 ---\n", .{});

    var running = true;
    var pc: u64 = 0;

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
                    std.debug.print("\n[VMM] EC=0x{X}\n", .{ec});
                    running = false;
                },
            }
        } else {
            running = false;
        }
    }

    _ = hv_vcpu_destroy(vcpu);
    _ = hv_vm_unmap(MEM_ADDR, MEM_SIZE);
    _ = hv_vm_destroy();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Demo A 完了!\n", .{});
    std.debug.print("========================================\n", .{});
}
