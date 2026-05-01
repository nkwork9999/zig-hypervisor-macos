const std = @import("std");

// ============== Constants ==============

pub const hv_return_t = i32;
pub const HV_SUCCESS: hv_return_t = 0;
pub const HV_MEMORY_READ: u64 = 1 << 0;
pub const HV_MEMORY_WRITE: u64 = 1 << 1;
pub const HV_MEMORY_EXEC: u64 = 1 << 2;

pub const HV_REG_X0: u32 = 0;
pub const HV_REG_PC: u32 = 31;
pub const HV_REG_CPSR: u32 = 34;
pub const HV_SYS_REG_VBAR_EL1: u16 = 0xC600;
pub const HV_SYS_REG_SP_EL0: u16 = 0xC208;
pub const HV_SYS_REG_SP_EL1: u16 = 0xE208;

pub const EC_HVC: u32 = 0x16;
pub const EC_SMC: u32 = 0x17;
pub const EC_DATA_ABORT: u32 = 0x24;
pub const EC_BRK: u32 = 0x3C;

// PSCI function IDs (SMC32)
pub const PSCI_VERSION: u64 = 0x84000000;
pub const PSCI_CPU_OFF: u64 = 0x84000002;
pub const PSCI_SYSTEM_OFF: u64 = 0x84000008;
pub const PSCI_SYSTEM_RESET: u64 = 0x84000009;
pub const PSCI_FEATURES: u64 = 0x8400000A;
pub const PSCI_VERSION_1_1: u64 = 0x00010001;
pub const HV_EXIT_REASON_CANCELED: u32 = 0;
pub const HV_EXIT_REASON_EXCEPTION: u32 = 1;
pub const HV_EXIT_REASON_VTIMER_ACTIVATED: u32 = 2;

// AArch64 例外ベクタテーブル offset (Current EL SPx)
pub const VEC_OFFSET_SPX_SYNC: usize = 0x200;
pub const VEC_OFFSET_SPX_IRQ: usize = 0x280;
pub const VEC_OFFSET_SPX_FIQ: usize = 0x300;
pub const VEC_OFFSET_SPX_SERROR: usize = 0x380;

// hv_interrupt_type_t (Apple Hypervisor.framework)
pub const HV_INTERRUPT_TYPE_IRQ: u32 = 0;
pub const HV_INTERRUPT_TYPE_FIQ: u32 = 1;

// CPSR value for EL1h with all DAIF masked
pub const CPSR_EL1H_DAIF_MASKED: u64 = 0x3c5;

pub const MEM_SIZE: usize = 0x200000;
pub const MEM_ADDR: u64 = 0x40000000;
pub const CODE_OFFSET: u64 = 0x1000;
pub const UART_BASE: u64 = 0x09000000;
pub const UART_DR: u64 = UART_BASE + 0x00;
pub const UART_FR: u64 = UART_BASE + 0x18;

// ============== Instruction Writer ==============

pub fn writeInst(mem: []u8, off: *usize, inst: u32) void {
    mem[off.*] = @intCast(inst & 0xFF);
    mem[off.* + 1] = @intCast((inst >> 8) & 0xFF);
    mem[off.* + 2] = @intCast((inst >> 16) & 0xFF);
    mem[off.* + 3] = @intCast((inst >> 24) & 0xFF);
    off.* += 4;
}

pub fn readInst(mem: []const u8, off: usize) u32 {
    return @as(u32, mem[off]) |
        (@as(u32, mem[off + 1]) << 8) |
        (@as(u32, mem[off + 2]) << 16) |
        (@as(u32, mem[off + 3]) << 24);
}

// ============== Syndrome Parsing ==============

pub fn extractEC(syndrome: u64) u32 {
    return @as(u32, @intCast((syndrome >> 26) & 0x3F));
}

pub fn isWrite(syndrome: u64) bool {
    return ((syndrome >> 6) & 1) == 1;
}

pub fn extractReg(syndrome: u64) u32 {
    return @as(u32, @intCast((syndrome >> 16) & 0x1F));
}

pub fn isUartRange(ipa: u64) bool {
    return ipa >= UART_BASE and ipa < UART_BASE + 0x1000;
}

// ============== Exception Vector ==============

pub const BRK_INST: u32 = 0xD4201FE0; // bytes in memory (LE): E0 1F 20 D4

pub fn fillExceptionVector(mem: []u8) void {
    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        mem[i] = 0xE0;
        mem[i + 1] = 0x1F;
        mem[i + 2] = 0x20;
        mem[i + 3] = 0xD4;
    }
}

// ============== ELF Loader ==============

pub const ELF_MAGIC = "\x7fELF";

pub const Elf64Header = extern struct {
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

pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const PT_LOAD: u32 = 1;

pub const ElfLoadResult = struct {
    entry_point: u64,
    loaded: bool,
};

pub fn loadElf(elf_data: []const u8, guest_mem: []u8, mem_base: u64) ElfLoadResult {
    if (elf_data.len < @sizeOf(Elf64Header)) {
        std.debug.print("[ELF] ファイルが小さすぎる\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }

    if (!std.mem.eql(u8, elf_data[0..4], ELF_MAGIC)) {
        std.debug.print("[ELF] 無効なマジック\n", .{});
        return .{ .entry_point = 0, .loaded = false };
    }

    const header: *const Elf64Header = @ptrCast(@alignCast(elf_data.ptr));

    if (header.e_machine != 0xB7) {
        std.debug.print("[ELF] 非AArch64バイナリ: 0x{X}\n", .{header.e_machine});
        return .{ .entry_point = 0, .loaded = false };
    }

    std.debug.print("[ELF] エントリポイント: 0x{X}\n", .{header.e_entry});
    std.debug.print("[ELF] Program Headers: {} 個\n", .{header.e_phnum});

    var i: u16 = 0;
    while (i < header.e_phnum) : (i += 1) {
        const ph_offset = header.e_phoff + i * header.e_phentsize;
        if (ph_offset + @sizeOf(Elf64Phdr) > elf_data.len) break;

        const phdr: *const Elf64Phdr = @ptrCast(@alignCast(elf_data.ptr + ph_offset));

        if (phdr.p_type != PT_LOAD) continue;

        std.debug.print("[ELF] LOAD: vaddr=0x{X} filesz={} memsz={}\n", .{
            phdr.p_vaddr, phdr.p_filesz, phdr.p_memsz,
        });

        const dest_offset = phdr.p_vaddr - mem_base;
        if (dest_offset + phdr.p_filesz > guest_mem.len) {
            std.debug.print("[ELF] メモリ範囲外\n", .{});
            continue;
        }

        const src = elf_data[phdr.p_offset..][0..phdr.p_filesz];
        const dest = guest_mem[dest_offset..][0..phdr.p_filesz];
        @memcpy(dest, src);

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

// ============== Demo D Helpers ==============

// SUB Xd, Xn, Xm (shifted register, LSL #0)
pub fn encodeSub(rd: u5, rn: u5, rm: u5) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ADD Xd, Xn, #imm12
pub fn encodeAddImm(rd: u5, rn: u5, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// SUBS Xd, Xn, #imm12 (sets flags)
pub fn encodeSubsImm(rd: u5, rn: u5, imm12: u12) u32 {
    return 0xF1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// B.cond offset — cond=0xC for b.gt
pub fn encodeBranchGT(from: usize, to: usize) u32 {
    const branch_offset = @as(i32, @intCast(@as(i64, @intCast(to)) - @as(i64, @intCast(from)))) >> 2;
    return 0x5400000C | (@as(u32, @bitCast(branch_offset & 0x7FFFF)) << 5);
}

// BRK #0
pub const INST_BRK_0: u32 = 0xD4200000;

// Timer CVAL calculation: CNTVCT_EL0 = mach_absolute_time() - vtimer_offset
// To fire in `delay` ticks: cval = now + delay - vtimer_offset
pub fn computeTimerCval(now: u64, delay: u64, vtimer_offset: u64) u64 {
    return now +% delay -% vtimer_offset;
}

// HV sys_reg IDs for virtual timer (from Hypervisor.framework headers)
pub const HV_SYS_REG_CNTV_CTL_EL0: u16 = 0xDF19;
pub const HV_SYS_REG_CNTV_CVAL_EL0: u16 = 0xDF1A;

// ============== vTimer Helpers (Demo D) ==============

// ARM64 system register instruction encodings for virtual timer
// MSR CNTV_TVAL_EL0, Xn — set countdown value
pub fn encodeMsrCntvTval(rt: u5) u32 {
    return 0xD51BE300 | @as(u32, rt);
}

// MSR CNTV_CTL_EL0, Xn — enable/disable timer
pub fn encodeMsrCntvCtl(rt: u5) u32 {
    return 0xD51BE320 | @as(u32, rt);
}

// MRS Xn, CNTVCT_EL0 — read virtual count
pub fn encodeMrsCntvct(rt: u5) u32 {
    return 0xD53BE040 | @as(u32, rt);
}

// B . (branch to self) — used as timer wait point
pub const INST_B_SELF: u32 = 0x14000000;

// MOVZ Xd, #imm16
pub fn encodeMovz(rd: u5, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

// MOVK Xd, #imm16, LSL #16
pub fn encodeMovk16(rd: u5, imm16: u16) u32 {
    return 0xF2A00000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

// Emit instructions to load a 32-bit immediate into Xd (movz + optional movk)
pub fn emitLoadImm32(mem: []u8, off: *usize, rd: u5, value: u32) void {
    const lo: u16 = @intCast(value & 0xFFFF);
    const hi: u16 = @intCast((value >> 16) & 0xFFFF);
    writeInst(mem, off, encodeMovz(rd, lo));
    if (hi != 0) {
        writeInst(mem, off, encodeMovk16(rd, hi));
    }
}

// Emit UART string output (mov x2, #ch; str x2, [x1] for each char)
pub fn emitUartString(mem: []u8, off: *usize, msg: []const u8) void {
    for (msg) |ch| {
        writeInst(mem, off, encodeMovz(2, @as(u16, ch)));
        writeInst(mem, off, 0xF9000022); // str x2, [x1]
    }
}

// ============== Branch Encoding (Demo B) ==============

pub fn encodeBranchGE(from: usize, to: usize) u32 {
    const branch_offset = @as(i32, @intCast(@as(i64, @intCast(to)) - @as(i64, @intCast(from)))) >> 2;
    return 0x5400000A | (@as(u32, @bitCast(branch_offset & 0x7FFFF)) << 5);
}

pub fn encodeUnconditionalBranch(from: usize, to: usize) u32 {
    const offset = @as(i32, @intCast(@as(i64, @intCast(to)) - @as(i64, @intCast(from)))) >> 2;
    return 0x14000000 | @as(u32, @bitCast(offset & 0x3FFFFFF));
}

// ============== Tests ==============

test "writeInst writes little-endian" {
    var mem: [8]u8 = undefined;
    var off: usize = 0;
    writeInst(&mem, &off, 0xD4200000);
    try std.testing.expectEqual(@as(usize, 4), off);
    try std.testing.expectEqual(@as(u8, 0x00), mem[0]);
    try std.testing.expectEqual(@as(u8, 0x00), mem[1]);
    try std.testing.expectEqual(@as(u8, 0x20), mem[2]);
    try std.testing.expectEqual(@as(u8, 0xD4), mem[3]);
}

test "writeInst sequential" {
    var mem: [12]u8 = undefined;
    var off: usize = 0;
    writeInst(&mem, &off, 0xAABBCCDD);
    writeInst(&mem, &off, 0x11223344);
    try std.testing.expectEqual(@as(usize, 8), off);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), readInst(&mem, 0));
    try std.testing.expectEqual(@as(u32, 0x11223344), readInst(&mem, 4));
}

test "readInst roundtrip" {
    var mem: [4]u8 = undefined;
    var off: usize = 0;
    const inst: u32 = 0xD2A12001; // mov x1, #0x0900, lsl #16
    writeInst(&mem, &off, inst);
    try std.testing.expectEqual(inst, readInst(&mem, 0));
}

test "extractEC data abort" {
    // EC=0x24 at bits [31:26] → syndrome = 0x24 << 26 = 0x90000000
    const syn: u64 = @as(u64, EC_DATA_ABORT) << 26;
    try std.testing.expectEqual(EC_DATA_ABORT, extractEC(syn));
}

test "extractEC BRK" {
    const syn: u64 = @as(u64, EC_BRK) << 26;
    try std.testing.expectEqual(EC_BRK, extractEC(syn));
}

test "isWrite from syndrome" {
    // bit 6 set = write
    const write_syn: u64 = (@as(u64, EC_DATA_ABORT) << 26) | (1 << 6);
    const read_syn: u64 = (@as(u64, EC_DATA_ABORT) << 26);
    try std.testing.expect(isWrite(write_syn));
    try std.testing.expect(!isWrite(read_syn));
}

test "extractReg from syndrome" {
    // register number at bits [20:16]
    const reg5_syn: u64 = (@as(u64, 5) << 16);
    try std.testing.expectEqual(@as(u32, 5), extractReg(reg5_syn));

    const reg31_syn: u64 = (@as(u64, 31) << 16);
    try std.testing.expectEqual(@as(u32, 31), extractReg(reg31_syn));

    const reg0_syn: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), extractReg(reg0_syn));
}

test "isUartRange" {
    try std.testing.expect(isUartRange(UART_BASE));
    try std.testing.expect(isUartRange(UART_BASE + 0x18));
    try std.testing.expect(isUartRange(UART_BASE + 0xFFF));
    try std.testing.expect(!isUartRange(UART_BASE + 0x1000));
    try std.testing.expect(!isUartRange(0));
    try std.testing.expect(!isUartRange(MEM_ADDR));
}

test "fillExceptionVector" {
    var mem: [0x800]u8 = undefined;
    @memset(&mem, 0);
    fillExceptionVector(&mem);

    // Check first instruction
    try std.testing.expectEqual(@as(u8, 0xE0), mem[0]);
    try std.testing.expectEqual(@as(u8, 0x1F), mem[1]);
    try std.testing.expectEqual(@as(u8, 0x20), mem[2]);
    try std.testing.expectEqual(@as(u8, 0xD4), mem[3]);

    // Check last instruction (0x7FC)
    try std.testing.expectEqual(@as(u8, 0xE0), mem[0x7FC]);
    try std.testing.expectEqual(@as(u8, 0x1F), mem[0x7FD]);
    try std.testing.expectEqual(@as(u8, 0x20), mem[0x7FE]);
    try std.testing.expectEqual(@as(u8, 0xD4), mem[0x7FF]);

    // All 512 instructions should be the same BRK pattern
    var i: usize = 0;
    while (i < 0x800) : (i += 4) {
        try std.testing.expectEqual(@as(u32, BRK_INST), readInst(&mem, i));
    }
}

test "loadElf rejects too small data" {
    const tiny = [_]u8{ 0x7f, 'E', 'L', 'F' };
    var guest_mem: [MEM_SIZE]u8 = undefined;
    const result = loadElf(&tiny, &guest_mem, MEM_ADDR);
    try std.testing.expect(!result.loaded);
    try std.testing.expectEqual(@as(u64, 0), result.entry_point);
}

test "loadElf rejects bad magic" {
    var bad_elf: [@sizeOf(Elf64Header)]u8 align(@alignOf(Elf64Header)) = undefined;
    @memset(&bad_elf, 0);
    bad_elf[0] = 0x00;
    bad_elf[1] = 'E';
    bad_elf[2] = 'L';
    bad_elf[3] = 'F';
    var guest_mem: [MEM_SIZE]u8 = undefined;
    const result = loadElf(&bad_elf, &guest_mem, MEM_ADDR);
    try std.testing.expect(!result.loaded);
}

test "loadElf rejects non-AArch64" {
    var elf_data: [@sizeOf(Elf64Header)]u8 align(@alignOf(Elf64Header)) = undefined;
    @memset(&elf_data, 0);
    // Set ELF magic
    elf_data[0] = 0x7f;
    elf_data[1] = 'E';
    elf_data[2] = 'L';
    elf_data[3] = 'F';
    // e_machine at offset 18 (little-endian), set to x86_64 (0x3E)
    elf_data[18] = 0x3E;
    elf_data[19] = 0x00;
    var guest_mem: [MEM_SIZE]u8 = undefined;
    const result = loadElf(&elf_data, &guest_mem, MEM_ADDR);
    try std.testing.expect(!result.loaded);
}

test "loadElf accepts valid AArch64 ELF with PT_LOAD" {
    // Build a minimal valid ELF with one PT_LOAD segment
    const phdr_size = @sizeOf(Elf64Phdr);
    const ehdr_size = @sizeOf(Elf64Header);
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const total_size = ehdr_size + phdr_size + payload.len;

    var elf_data: [total_size]u8 align(@alignOf(Elf64Header)) = undefined;
    @memset(&elf_data, 0);

    // ELF header
    const header: *Elf64Header = @ptrCast(@alignCast(&elf_data));
    header.e_ident[0] = 0x7f;
    header.e_ident[1] = 'E';
    header.e_ident[2] = 'L';
    header.e_ident[3] = 'F';
    header.e_machine = 0xB7; // EM_AARCH64
    header.e_entry = MEM_ADDR + 0x1000;
    header.e_phoff = ehdr_size;
    header.e_phentsize = phdr_size;
    header.e_phnum = 1;

    // Program header
    const phdr: *Elf64Phdr = @ptrCast(@alignCast(elf_data[ehdr_size..].ptr));
    phdr.p_type = PT_LOAD;
    phdr.p_offset = ehdr_size + phdr_size;
    phdr.p_vaddr = MEM_ADDR + 0x1000;
    phdr.p_paddr = MEM_ADDR + 0x1000;
    phdr.p_filesz = payload.len;
    phdr.p_memsz = payload.len;

    // Payload
    @memcpy(elf_data[ehdr_size + phdr_size ..][0..payload.len], &payload);

    // Load
    var guest_mem: [0x2000]u8 = undefined;
    @memset(&guest_mem, 0);
    const result = loadElf(&elf_data, &guest_mem, MEM_ADDR);

    try std.testing.expect(result.loaded);
    try std.testing.expectEqual(MEM_ADDR + 0x1000, result.entry_point);

    // Verify payload was copied to correct offset
    try std.testing.expectEqual(@as(u8, 0xDE), guest_mem[0x1000]);
    try std.testing.expectEqual(@as(u8, 0xAD), guest_mem[0x1001]);
    try std.testing.expectEqual(@as(u8, 0xBE), guest_mem[0x1002]);
    try std.testing.expectEqual(@as(u8, 0xEF), guest_mem[0x1003]);
}

test "loadElf BSS zero-fill" {
    const ehdr_size = @sizeOf(Elf64Header);
    const phdr_size = @sizeOf(Elf64Phdr);
    const payload = [_]u8{ 0xAA, 0xBB };
    const total_size = ehdr_size + phdr_size + payload.len;

    var elf_data: [total_size]u8 align(@alignOf(Elf64Header)) = undefined;
    @memset(&elf_data, 0);

    const header: *Elf64Header = @ptrCast(@alignCast(&elf_data));
    header.e_ident[0] = 0x7f;
    header.e_ident[1] = 'E';
    header.e_ident[2] = 'L';
    header.e_ident[3] = 'F';
    header.e_machine = 0xB7;
    header.e_entry = MEM_ADDR;
    header.e_phoff = ehdr_size;
    header.e_phentsize = phdr_size;
    header.e_phnum = 1;

    const phdr: *Elf64Phdr = @ptrCast(@alignCast(elf_data[ehdr_size..].ptr));
    phdr.p_type = PT_LOAD;
    phdr.p_offset = ehdr_size + phdr_size;
    phdr.p_vaddr = MEM_ADDR;
    phdr.p_paddr = MEM_ADDR;
    phdr.p_filesz = payload.len;
    phdr.p_memsz = payload.len + 8; // 8 bytes BSS

    @memcpy(elf_data[ehdr_size + phdr_size ..][0..payload.len], &payload);

    var guest_mem: [0x100]u8 = undefined;
    @memset(&guest_mem, 0xFF); // fill with non-zero to verify BSS zeroing
    const result = loadElf(&elf_data, &guest_mem, MEM_ADDR);

    try std.testing.expect(result.loaded);
    // Payload copied
    try std.testing.expectEqual(@as(u8, 0xAA), guest_mem[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), guest_mem[1]);
    // BSS zeroed
    try std.testing.expectEqual(@as(u8, 0), guest_mem[2]);
    try std.testing.expectEqual(@as(u8, 0), guest_mem[9]);
}

test "encodeBranchGE backward branch" {
    // from=0x1028, to=0x1010 → backward by -24 bytes → offset = -6
    const inst = encodeBranchGE(0x1028, 0x1010);
    // b.ge with imm19 = -6, condition = 0xA (ge)
    // imm19 field bits [23:5], condition bits [3:0]
    try std.testing.expectEqual(@as(u32, 0xA), inst & 0xF); // condition = ge
    // Verify it produces valid instruction (top bits = 0101_0100)
    try std.testing.expectEqual(@as(u32, 0x54), (inst >> 24) & 0xFF);
}

test "encodeUnconditionalBranch backward" {
    const inst = encodeUnconditionalBranch(0x1020, 0x1010);
    // b with offset = -4 words → 0x17FFFFFC
    // top 6 bits of unconditional branch: 000101 = 0x14..0x17
    try std.testing.expectEqual(@as(u32, 0x17), (inst >> 24) & 0xFF);
}

test "constants consistency" {
    // Verify constants match what the demos use
    try std.testing.expectEqual(@as(u64, 0x40000000), MEM_ADDR);
    try std.testing.expectEqual(@as(usize, 0x200000), MEM_SIZE);
    try std.testing.expectEqual(@as(u64, 0x09000000), UART_BASE);
    try std.testing.expectEqual(@as(u64, 0x1000), CODE_OFFSET);
    try std.testing.expectEqual(@as(u32, 31), HV_REG_PC);
    try std.testing.expectEqual(@as(u32, 34), HV_REG_CPSR);
    try std.testing.expectEqual(UART_BASE, UART_DR);
    try std.testing.expectEqual(UART_BASE + 0x18, UART_FR);
}

test "demo_a arithmetic instructions encode correctly" {
    // Verify the specific ARM64 instructions used in demo_a
    var mem: [256]u8 = undefined;
    var off: usize = 0;

    // mov x1, #0x0900, lsl #16 (UART addr setup)
    writeInst(&mem, &off, 0xD2A12001);
    try std.testing.expectEqual(@as(u32, 0xD2A12001), readInst(&mem, 0));

    // mov x0, #0
    writeInst(&mem, &off, 0xD2800000);
    try std.testing.expectEqual(@as(u32, 0xD2800000), readInst(&mem, 4));

    // add x0, x0, #1
    writeInst(&mem, &off, 0x91000400);
    try std.testing.expectEqual(@as(u32, 0x91000400), readInst(&mem, 8));

    // brk #0
    writeInst(&mem, &off, 0xD4200000);
    try std.testing.expectEqual(@as(u32, 0xD4200000), readInst(&mem, 12));
}

test "mov immediate character encoding" {
    // Demo A/B encode characters as: 0xD2800002 | (ch << 5) → mov x2, #ch
    const ch: u8 = 'R'; // 0x52
    const inst: u32 = 0xD2800002 | (@as(u32, ch) << 5);
    // Verify the character can be extracted back
    const extracted = @as(u8, @intCast((inst >> 5) & 0xFF));
    try std.testing.expectEqual(ch, extracted);
}

test "str x2, [x1] encoding" {
    // All demos use 0xF9000022 for str x2, [x1]
    const inst: u32 = 0xF9000022;
    // Rt = bits [4:0] = x2
    try std.testing.expectEqual(@as(u32, 2), inst & 0x1F);
    // Rn = bits [9:5] = x1
    try std.testing.expectEqual(@as(u32, 1), (inst >> 5) & 0x1F);
}

// ============== vTimer Tests ==============

test "encodeMsrCntvTval x0" {
    try std.testing.expectEqual(@as(u32, 0xD51BE300), encodeMsrCntvTval(0));
}

test "encodeMsrCntvCtl x2" {
    try std.testing.expectEqual(@as(u32, 0xD51BE322), encodeMsrCntvCtl(2));
}

test "encodeMrsCntvct x0" {
    try std.testing.expectEqual(@as(u32, 0xD53BE040), encodeMrsCntvct(0));
}

test "encodeMovz" {
    // mov x0, #0 = 0xD2800000
    try std.testing.expectEqual(@as(u32, 0xD2800000), encodeMovz(0, 0));
    // mov x2, #1 = 0xD2800022
    try std.testing.expectEqual(@as(u32, 0xD2800022), encodeMovz(2, 1));
    // mov x3, #3 = 0xD2800063
    try std.testing.expectEqual(@as(u32, 0xD2800063), encodeMovz(3, 3));
}

test "encodeMovk16" {
    // movk x0, #0x100, lsl #16 = 0xF2A02000
    try std.testing.expectEqual(@as(u32, 0xF2A02000), encodeMovk16(0, 0x100));
}

test "emitLoadImm32 small value" {
    var mem: [8]u8 = undefined;
    var off: usize = 0;
    emitLoadImm32(&mem, &off, 0, 42);
    try std.testing.expectEqual(@as(usize, 4), off); // only movz, no movk
    try std.testing.expectEqual(encodeMovz(0, 42), readInst(&mem, 0));
}

test "emitLoadImm32 large value" {
    var mem: [8]u8 = undefined;
    var off: usize = 0;
    emitLoadImm32(&mem, &off, 0, 0x1000000); // 16M
    try std.testing.expectEqual(@as(usize, 8), off); // movz + movk
    try std.testing.expectEqual(encodeMovz(0, 0), readInst(&mem, 0));
    try std.testing.expectEqual(encodeMovk16(0, 0x100), readInst(&mem, 4));
}

test "emitUartString" {
    var mem: [64]u8 = undefined;
    var off: usize = 0;
    emitUartString(&mem, &off, "AB");
    try std.testing.expectEqual(@as(usize, 16), off); // 2 chars × 2 insts × 4 bytes
    // First char 'A' = 0x41
    try std.testing.expectEqual(encodeMovz(2, 'A'), readInst(&mem, 0));
    try std.testing.expectEqual(@as(u32, 0xF9000022), readInst(&mem, 4));
    // Second char 'B' = 0x42
    try std.testing.expectEqual(encodeMovz(2, 'B'), readInst(&mem, 8));
    try std.testing.expectEqual(@as(u32, 0xF9000022), readInst(&mem, 12));
}

test "INST_B_SELF encoding" {
    // b . = branch with offset 0
    try std.testing.expectEqual(@as(u32, 0x14000000), INST_B_SELF);
}

test "vtimer exit reason constant" {
    try std.testing.expectEqual(@as(u32, 2), HV_EXIT_REASON_VTIMER_ACTIVATED);
    try std.testing.expect(HV_EXIT_REASON_VTIMER_ACTIVATED != HV_EXIT_REASON_EXCEPTION);
}

// ============== Demo D Tests ==============

test "encodeSub x4, x4, x3" {
    // Demo D uses sub x4, x4, x3 = 0xCB030084
    try std.testing.expectEqual(@as(u32, 0xCB030084), encodeSub(4, 4, 3));
}

test "encodeAddImm add x2, x4, #'0'" {
    // Demo D: add x2, x4, #0x30 = 0x9100C082 (Xn=4 critical, bug fix)
    try std.testing.expectEqual(@as(u32, 0x9100C082), encodeAddImm(2, 4, 0x30));
}

test "encodeAddImm field layout" {
    // Verify Rn bits [9:5]
    const inst = encodeAddImm(2, 4, 0x30);
    try std.testing.expectEqual(@as(u32, 2), inst & 0x1F);        // Rd
    try std.testing.expectEqual(@as(u32, 4), (inst >> 5) & 0x1F); // Rn (was the bug: was 2, must be 4)
    try std.testing.expectEqual(@as(u32, 0x30), (inst >> 10) & 0xFFF); // imm12
}

test "encodeSubsImm subs x3, x3, #1" {
    // Demo D: subs x3, x3, #1 = 0xF1000463
    try std.testing.expectEqual(@as(u32, 0xF1000463), encodeSubsImm(3, 3, 1));
}

test "encodeBranchGT backward" {
    // b.gt has condition code 0xC
    const inst = encodeBranchGT(0x1100, 0x1080);
    try std.testing.expectEqual(@as(u32, 0xC), inst & 0xF); // cond = gt
    try std.testing.expectEqual(@as(u32, 0x54), (inst >> 24) & 0xFF);
}

test "encodeBranchGT vs encodeBranchGE differ only in condition" {
    const gt = encodeBranchGT(0x100, 0x80);
    const ge = encodeBranchGE(0x100, 0x80);
    // Same except last 4 bits (condition)
    try std.testing.expectEqual(gt & ~@as(u32, 0xF), ge & ~@as(u32, 0xF));
    try std.testing.expectEqual(@as(u32, 0xC), gt & 0xF);
    try std.testing.expectEqual(@as(u32, 0xA), ge & 0xF);
}

test "INST_BRK_0 value" {
    try std.testing.expectEqual(@as(u32, 0xD4200000), INST_BRK_0);
}

test "computeTimerCval basic" {
    // now=1000, delay=500, offset=0 → cval=1500
    try std.testing.expectEqual(@as(u64, 1500), computeTimerCval(1000, 500, 0));
}

test "computeTimerCval with offset" {
    // now=1_000_000, delay=12_000_000, offset=500_000 → cval=12_500_000
    try std.testing.expectEqual(@as(u64, 12_500_000), computeTimerCval(1_000_000, 12_000_000, 500_000));
}

test "computeTimerCval does not overflow on large values" {
    // mach_absolute_time() returns large u64 values — verify no UB
    const now: u64 = 0xFFFF_FFFF_FFFF_0000;
    const delay: u64 = 12_000_000;
    const offset: u64 = 0x1_0000_0000;
    const cval = computeTimerCval(now, delay, offset);
    // Just check it returns (wrapping arithmetic is intentional for clock math)
    try std.testing.expectEqual(now +% delay -% offset, cval);
}

test "HV_SYS_REG timer constants match Apple headers" {
    try std.testing.expectEqual(@as(u16, 0xDF19), HV_SYS_REG_CNTV_CTL_EL0);
    try std.testing.expectEqual(@as(u16, 0xDF1A), HV_SYS_REG_CNTV_CVAL_EL0);
}

test "HV_SYS_REG encoding formula consistency" {
    // HV_SYS_REG = (op0<<14) | (op1<<11) | (CRn<<7) | (CRm<<3) | op2
    // CNTV_CTL_EL0: op0=3, op1=3, CRn=14, CRm=3, op2=1
    const cntv_ctl: u16 = (3 << 14) | (3 << 11) | (14 << 7) | (3 << 3) | 1;
    try std.testing.expectEqual(HV_SYS_REG_CNTV_CTL_EL0, cntv_ctl);
    // CNTV_CVAL_EL0: op2=2
    const cntv_cval: u16 = (3 << 14) | (3 << 11) | (14 << 7) | (3 << 3) | 2;
    try std.testing.expectEqual(HV_SYS_REG_CNTV_CVAL_EL0, cntv_cval);
    // VBAR_EL1: op0=3, op1=0, CRn=12, CRm=0, op2=0 = 0xC600
    const vbar_el1: u16 = (3 << 14) | (0 << 11) | (12 << 7) | (0 << 3) | 0;
    try std.testing.expectEqual(HV_SYS_REG_VBAR_EL1, vbar_el1);
}

test "demo_d wait loop instruction is b ." {
    // demo_d uses b . (branch to self, offset=0) as timer wait
    try std.testing.expectEqual(@as(u32, 0x14000000), INST_B_SELF);
    // Verify it's a valid unconditional branch
    try std.testing.expectEqual(@as(u32, 0x14), (INST_B_SELF >> 24) & 0xFF);
    // Offset = 0 (self)
    try std.testing.expectEqual(@as(u32, 0), INST_B_SELF & 0x3FFFFFF);
}

test "demo_d guest code layout" {
    // Simulate demo_d code gen and verify the critical instructions are correct
    var mem: [512]u8 = undefined;
    @memset(&mem, 0);
    var off: usize = 0;

    // mov x1, #0x0900, lsl #16 (UART base)
    writeInst(&mem, &off, 0xD2A12001);
    // Skip banner emission for test brevity
    emitUartString(&mem, &off, "X");

    // mov x3, #5 (TICK_COUNT)
    writeInst(&mem, &off, 0xD2800003 | (@as(u32, 5) << 5));

    const tick_start = off;
    // b . (wait point)
    writeInst(&mem, &off, INST_B_SELF);

    emitUartString(&mem, &off, "T");

    // mov x4, #6; sub x4, x4, x3; add x2, x4, #'0'
    writeInst(&mem, &off, encodeMovz(4, 6));
    writeInst(&mem, &off, encodeSub(4, 4, 3));
    writeInst(&mem, &off, encodeAddImm(2, 4, 0x30));
    writeInst(&mem, &off, 0xF9000022); // str x2, [x1]

    // subs x3, x3, #1
    writeInst(&mem, &off, encodeSubsImm(3, 3, 1));
    // b.gt tick_start
    writeInst(&mem, &off, encodeBranchGT(off, tick_start));
    // brk #0
    writeInst(&mem, &off, INST_BRK_0);

    // Verify the wait instruction is at tick_start
    try std.testing.expectEqual(INST_B_SELF, readInst(&mem, tick_start));
    // Verify brk is last
    try std.testing.expectEqual(INST_BRK_0, readInst(&mem, off - 4));
    // Verify b.gt branches backward to tick_start
    const bgt = readInst(&mem, off - 8);
    try std.testing.expectEqual(@as(u32, 0xC), bgt & 0xF); // cond = gt
}

// ============== GIC / IRQ Tests ==============

test "HV_REG_CPSR correct index (regression: was 32, should be 34)" {
    // FPCR=32, FPSR=33, CPSR=34 in hv_reg_t enum
    try std.testing.expectEqual(@as(u32, 34), HV_REG_CPSR);
}

test "CPSR EL1h DAIF masked value" {
    // 0x3c5 = DAIF=1111 (all masked), M[4]=0 (AArch64), M[3:0]=0101 (EL1h)
    try std.testing.expectEqual(@as(u64, 0x3c5), CPSR_EL1H_DAIF_MASKED);
    // Decompose:
    const cpsr = CPSR_EL1H_DAIF_MASKED;
    try std.testing.expectEqual(@as(u64, 0b0101), cpsr & 0xF); // M[3:0] = EL1h
    try std.testing.expectEqual(@as(u64, 0b1111), (cpsr >> 6) & 0xF); // DAIF all masked
}

test "HV_INTERRUPT_TYPE constants" {
    try std.testing.expectEqual(@as(u32, 0), HV_INTERRUPT_TYPE_IRQ);
    try std.testing.expectEqual(@as(u32, 1), HV_INTERRUPT_TYPE_FIQ);
}

test "PSCI function IDs are SMC32 fast call format" {
    // SMC32 fast call: bit 31 set, bits 31..30 = "01" (Fast call, SMC32)
    // 0x84000000 = 0b1000_0100_0000_0000_0000_0000_0000_0000
    try std.testing.expectEqual(@as(u64, 0x84000000), PSCI_VERSION);
    try std.testing.expectEqual(@as(u64, 0x84000008), PSCI_SYSTEM_OFF);
    try std.testing.expectEqual(@as(u64, 0x84000009), PSCI_SYSTEM_RESET);
    // bit 31 = 1 (Fast call)
    try std.testing.expect((PSCI_VERSION >> 31) & 1 == 1);
}

test "PSCI version 1.1 encoding" {
    // major=1 << 16 | minor=1
    try std.testing.expectEqual(@as(u64, 0x00010001), PSCI_VERSION_1_1);
    try std.testing.expectEqual(@as(u64, 1), PSCI_VERSION_1_1 >> 16);
    try std.testing.expectEqual(@as(u64, 1), PSCI_VERSION_1_1 & 0xFFFF);
}

test "EC_HVC value" {
    // ARM ARM: EC=0x16 for HVC instruction execution from AArch64
    try std.testing.expectEqual(@as(u32, 0x16), EC_HVC);
    try std.testing.expectEqual(@as(u32, 0x17), EC_SMC);
}

test "exception vector offsets for EL1h SPx" {
    // Each vector entry is 0x80 bytes. SPx group starts at 0x200.
    try std.testing.expectEqual(@as(usize, 0x200), VEC_OFFSET_SPX_SYNC);
    try std.testing.expectEqual(VEC_OFFSET_SPX_SYNC + 0x80, VEC_OFFSET_SPX_IRQ);
    try std.testing.expectEqual(VEC_OFFSET_SPX_IRQ + 0x80, VEC_OFFSET_SPX_FIQ);
    try std.testing.expectEqual(VEC_OFFSET_SPX_FIQ + 0x80, VEC_OFFSET_SPX_SERROR);
}

test "full exception vector table is 2KB" {
    // 16 entries × 128 bytes = 2048 = 0x800
    try std.testing.expectEqual(@as(usize, 0x800), 16 * 0x80);
}

test "UART FR busy flag logic" {
    // Demo C uses: if input_char == null → flags = 0x10 (BUSY), else 0x00
    const no_input: ?u8 = null;
    const has_input: ?u8 = 'a';
    const flags_empty: u64 = if (no_input == null) 0x10 else 0x00;
    const flags_ready: u64 = if (has_input == null) 0x10 else 0x00;
    try std.testing.expectEqual(@as(u64, 0x10), flags_empty);
    try std.testing.expectEqual(@as(u64, 0x00), flags_ready);
}
