// Flattened Device Tree (FDT) / Device Tree Blob (DTB) builder.
//
// Spec: https://www.devicetree.org/specifications/
// All multi-byte integers in DTB are big-endian.
//
// Layout:
//   [header 40B] [mem reserve block] [structure block] [strings block]

const std = @import("std");

pub const FDT_MAGIC: u32 = 0xd00dfeed;
pub const FDT_VERSION: u32 = 17;
pub const FDT_LAST_COMP_VERSION: u32 = 16;

// Structure block tokens
pub const FDT_BEGIN_NODE: u32 = 0x1;
pub const FDT_END_NODE: u32 = 0x2;
pub const FDT_PROP: u32 = 0x3;
pub const FDT_NOP: u32 = 0x4;
pub const FDT_END: u32 = 0x9;

pub const FdtHeader = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub const MemReserveEntry = struct {
    address: u64,
    size: u64,
};

// ============== Builder ==============

pub const DtbBuilder = struct {
    allocator: std.mem.Allocator,
    struct_block: std.ArrayList(u8),
    strings_block: std.ArrayList(u8),
    mem_reserve: std.ArrayList(MemReserveEntry),

    pub fn init(allocator: std.mem.Allocator) DtbBuilder {
        return .{
            .allocator = allocator,
            .struct_block = .empty,
            .strings_block = .empty,
            .mem_reserve = .empty,
        };
    }

    pub fn deinit(self: *DtbBuilder) void {
        self.struct_block.deinit(self.allocator);
        self.strings_block.deinit(self.allocator);
        self.mem_reserve.deinit(self.allocator);
    }

    pub fn addMemReserve(self: *DtbBuilder, address: u64, size: u64) !void {
        try self.mem_reserve.append(self.allocator, .{ .address = address, .size = size });
    }

    pub fn beginNode(self: *DtbBuilder, name: []const u8) !void {
        try self.writeU32BE(&self.struct_block, FDT_BEGIN_NODE);
        try self.struct_block.appendSlice(self.allocator, name);
        try self.struct_block.append(self.allocator, 0); // null terminator
        try self.padTo4(&self.struct_block);
    }

    pub fn endNode(self: *DtbBuilder) !void {
        try self.writeU32BE(&self.struct_block, FDT_END_NODE);
    }

    // Generic property with raw byte data
    pub fn prop(self: *DtbBuilder, name: []const u8, data: []const u8) !void {
        const name_off = try self.getStringOffset(name);
        try self.writeU32BE(&self.struct_block, FDT_PROP);
        try self.writeU32BE(&self.struct_block, @intCast(data.len));
        try self.writeU32BE(&self.struct_block, name_off);
        try self.struct_block.appendSlice(self.allocator, data);
        try self.padTo4(&self.struct_block);
    }

    pub fn propEmpty(self: *DtbBuilder, name: []const u8) !void {
        try self.prop(name, &[_]u8{});
    }

    pub fn propU32(self: *DtbBuilder, name: []const u8, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.prop(name, &buf);
    }

    // u64 encoded as 2 u32 cells (high, low), big-endian
    pub fn propU64(self: *DtbBuilder, name: []const u8, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intCast(value >> 32), .big);
        std.mem.writeInt(u32, buf[4..8], @intCast(value & 0xFFFF_FFFF), .big);
        try self.prop(name, &buf);
    }

    pub fn propString(self: *DtbBuilder, name: []const u8, value: []const u8) !void {
        // Need to include null terminator
        var data = try self.allocator.alloc(u8, value.len + 1);
        defer self.allocator.free(data);
        @memcpy(data[0..value.len], value);
        data[value.len] = 0;
        try self.prop(name, data);
    }

    pub fn propStringList(self: *DtbBuilder, name: []const u8, values: []const []const u8) !void {
        var total: usize = 0;
        for (values) |v| total += v.len + 1;
        var data = try self.allocator.alloc(u8, total);
        defer self.allocator.free(data);
        var i: usize = 0;
        for (values) |v| {
            @memcpy(data[i .. i + v.len], v);
            data[i + v.len] = 0;
            i += v.len + 1;
        }
        try self.prop(name, data);
    }

    pub fn propCells(self: *DtbBuilder, name: []const u8, cells: []const u32) !void {
        var data = try self.allocator.alloc(u8, cells.len * 4);
        defer self.allocator.free(data);
        for (cells, 0..) |c, idx| {
            std.mem.writeInt(u32, data[idx * 4 ..][0..4], c, .big);
        }
        try self.prop(name, data);
    }

    // Finalize into a complete DTB byte buffer.
    // Caller owns the returned slice (allocated with builder's allocator).
    pub fn finalize(self: *DtbBuilder) ![]u8 {
        // Close structure block with FDT_END
        try self.writeU32BE(&self.struct_block, FDT_END);

        const header_size: u32 = @sizeOf(FdtHeader);
        // Mem reserve: include {0, 0} terminator
        const mem_reserve_size: u32 = @intCast((self.mem_reserve.items.len + 1) * 16);
        const off_mem_rsvmap = header_size;
        const off_dt_struct = off_mem_rsvmap + mem_reserve_size;
        const off_dt_strings = off_dt_struct + @as(u32, @intCast(self.struct_block.items.len));
        const total_size = off_dt_strings + @as(u32, @intCast(self.strings_block.items.len));

        var out = try self.allocator.alloc(u8, total_size);

        // Header
        const header_bytes = out[0..header_size];
        writeHeaderField(header_bytes[0..4], FDT_MAGIC);
        writeHeaderField(header_bytes[4..8], total_size);
        writeHeaderField(header_bytes[8..12], off_dt_struct);
        writeHeaderField(header_bytes[12..16], off_dt_strings);
        writeHeaderField(header_bytes[16..20], off_mem_rsvmap);
        writeHeaderField(header_bytes[20..24], FDT_VERSION);
        writeHeaderField(header_bytes[24..28], FDT_LAST_COMP_VERSION);
        writeHeaderField(header_bytes[28..32], 0); // boot_cpuid_phys
        writeHeaderField(header_bytes[32..36], @intCast(self.strings_block.items.len));
        writeHeaderField(header_bytes[36..40], @intCast(self.struct_block.items.len));

        // Memory reservation block
        var mr_idx: usize = header_size;
        for (self.mem_reserve.items) |e| {
            std.mem.writeInt(u64, out[mr_idx..][0..8], e.address, .big);
            std.mem.writeInt(u64, out[mr_idx + 8 ..][0..8], e.size, .big);
            mr_idx += 16;
        }
        // Terminator {0, 0}
        std.mem.writeInt(u64, out[mr_idx..][0..8], 0, .big);
        std.mem.writeInt(u64, out[mr_idx + 8 ..][0..8], 0, .big);

        // Structure block
        @memcpy(out[off_dt_struct..][0..self.struct_block.items.len], self.struct_block.items);
        // Strings block
        @memcpy(out[off_dt_strings..][0..self.strings_block.items.len], self.strings_block.items);

        return out;
    }

    // ---- Internal ----

    fn writeU32BE(self: *DtbBuilder, list: *std.ArrayList(u8), value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try list.appendSlice(self.allocator, &buf);
    }

    fn padTo4(self: *DtbBuilder, list: *std.ArrayList(u8)) !void {
        const pad = (4 - (list.items.len % 4)) % 4;
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try list.append(self.allocator, 0);
        }
    }

    // Find or add a property name to the strings block; return its offset.
    fn getStringOffset(self: *DtbBuilder, name: []const u8) !u32 {
        // Linear search for existing (dedup)
        const block = self.strings_block.items;
        var i: usize = 0;
        while (i < block.len) {
            const len = std.mem.indexOfScalarPos(u8, block, i, 0) orelse break;
            if (std.mem.eql(u8, block[i..len], name)) {
                return @intCast(i);
            }
            i = len + 1;
        }
        // Not found: append
        const offset: u32 = @intCast(self.strings_block.items.len);
        try self.strings_block.appendSlice(self.allocator, name);
        try self.strings_block.append(self.allocator, 0);
        return offset;
    }
};

fn writeHeaderField(slot: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, slot, value, .big);
}

// ============== Parser (for testing/debug) ==============

pub const ParsedHeader = struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub fn parseHeader(data: []const u8) !ParsedHeader {
    if (data.len < @sizeOf(FdtHeader)) return error.TooSmall;
    return .{
        .magic = std.mem.readInt(u32, data[0..4], .big),
        .totalsize = std.mem.readInt(u32, data[4..8], .big),
        .off_dt_struct = std.mem.readInt(u32, data[8..12], .big),
        .off_dt_strings = std.mem.readInt(u32, data[12..16], .big),
        .off_mem_rsvmap = std.mem.readInt(u32, data[16..20], .big),
        .version = std.mem.readInt(u32, data[20..24], .big),
        .last_comp_version = std.mem.readInt(u32, data[24..28], .big),
        .size_dt_strings = std.mem.readInt(u32, data[32..36], .big),
        .size_dt_struct = std.mem.readInt(u32, data[36..40], .big),
    };
}

// Find a null-terminated string at `offset` in the strings block
pub fn getString(dtb: []const u8, strings_off: u32, offset: u32) ?[]const u8 {
    const base = strings_off + offset;
    if (base >= dtb.len) return null;
    const end = std.mem.indexOfScalarPos(u8, dtb, base, 0) orelse return null;
    return dtb[base..end];
}

// ============== ZigVM-specific DTB ==============
//
// Builds a minimal DTB that describes the ZigVM environment:
// - 2MB RAM at 0x40000000
// - PL011 UART at 0x09000000
// - Single ARMv8 CPU
// - ARMv8 generic timer (vTimer)
// - Basic chosen/compatible properties

pub const ZigVmDtbConfig = struct {
    mem_base: u64 = 0x40000000,
    mem_size: u64 = 0x8000000,
    uart_base: u64 = 0x09000000,
    uart_size: u64 = 0x1000,
    gic_dist_base: u64 = 0x08000000,
    gic_dist_size: u64 = 0x10000,
    gic_cpu_base: u64 = 0x08010000,
    gic_cpu_size: u64 = 0x10000,
    bootargs: []const u8 = "",
    initrd_start: u64 = 0,
    initrd_end: u64 = 0, // 0/0 means no initrd
};

pub const GIC_PHANDLE: u32 = 1;
pub const APB_PCLK_PHANDLE: u32 = 2;

pub fn buildZigVmDtb(allocator: std.mem.Allocator, cfg: ZigVmDtbConfig) ![]u8 {
    var b = DtbBuilder.init(allocator);
    defer b.deinit();

    // Root node
    try b.beginNode("");
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.propString("compatible", "zigvm,virt");
    try b.propString("model", "ZigVM");
    try b.propU32("interrupt-parent", GIC_PHANDLE);

    // /chosen
    try b.beginNode("chosen");
    try b.propString("bootargs", cfg.bootargs);
    if (cfg.initrd_end > cfg.initrd_start) {
        // linux,initrd-{start,end}: u64 properties (kernel reads via single property)
        var sbuf: [8]u8 = undefined;
        var ebuf: [8]u8 = undefined;
        std.mem.writeInt(u32, sbuf[0..4], @intCast(cfg.initrd_start >> 32), .big);
        std.mem.writeInt(u32, sbuf[4..8], @intCast(cfg.initrd_start & 0xFFFF_FFFF), .big);
        std.mem.writeInt(u32, ebuf[0..4], @intCast(cfg.initrd_end >> 32), .big);
        std.mem.writeInt(u32, ebuf[4..8], @intCast(cfg.initrd_end & 0xFFFF_FFFF), .big);
        try b.prop("linux,initrd-start", &sbuf);
        try b.prop("linux,initrd-end", &ebuf);
    }
    try b.endNode();

    // /memory@<addr>
    // Node name: "memory@40000000"
    var mem_name_buf: [32]u8 = undefined;
    const mem_name = try std.fmt.bufPrint(&mem_name_buf, "memory@{x}", .{cfg.mem_base});
    try b.beginNode(mem_name);
    try b.propString("device_type", "memory");
    // reg = <addr_high addr_low size_high size_low>
    try b.propCells("reg", &[_]u32{
        @intCast(cfg.mem_base >> 32),
        @intCast(cfg.mem_base & 0xFFFF_FFFF),
        @intCast(cfg.mem_size >> 32),
        @intCast(cfg.mem_size & 0xFFFF_FFFF),
    });
    try b.endNode();

    // /cpus
    try b.beginNode("cpus");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 0);
    try b.beginNode("cpu@0");
    try b.propString("device_type", "cpu");
    try b.propString("compatible", "arm,armv8");
    try b.propU32("reg", 0);
    try b.propString("enable-method", "psci");
    try b.endNode();
    try b.endNode();

    // /psci (PSCI 1.0 via HVC)
    try b.beginNode("psci");
    try b.propStringList("compatible", &[_][]const u8{ "arm,psci-1.0", "arm,psci-0.2", "arm,psci" });
    try b.propString("method", "hvc");
    try b.endNode();

    // /intc@<addr> — GICv2
    var intc_name_buf: [32]u8 = undefined;
    const intc_name = try std.fmt.bufPrint(&intc_name_buf, "intc@{x}", .{cfg.gic_dist_base});
    try b.beginNode(intc_name);
    try b.propString("compatible", "arm,cortex-a15-gic");
    try b.propU32("#interrupt-cells", 3);
    try b.propEmpty("interrupt-controller");
    try b.propU32("phandle", GIC_PHANDLE);
    // GICv2 reg: distributor + CPU interface
    try b.propCells("reg", &[_]u32{
        @intCast(cfg.gic_dist_base >> 32), @intCast(cfg.gic_dist_base & 0xFFFF_FFFF),
        @intCast(cfg.gic_dist_size >> 32), @intCast(cfg.gic_dist_size & 0xFFFF_FFFF),
        @intCast(cfg.gic_cpu_base >> 32),  @intCast(cfg.gic_cpu_base & 0xFFFF_FFFF),
        @intCast(cfg.gic_cpu_size >> 32),  @intCast(cfg.gic_cpu_size & 0xFFFF_FFFF),
    });
    try b.endNode();

    // /timer (ARMv8 arch timer)
    try b.beginNode("timer");
    try b.propString("compatible", "arm,armv8-timer");
    // interrupts = <type irq flags>, 4 timers (secure, non-secure, virtual, hyp)
    try b.propCells("interrupts", &[_]u32{
        1, 13, 0xff08, // secure phys timer (PPI 13)
        1, 14, 0xff08, // non-secure phys timer (PPI 14)
        1, 11, 0xff08, // virtual timer (PPI 11)
        1, 10, 0xff08, // hyp timer (PPI 10)
    });
    try b.endNode();

    // /apb-pclk: 24MHz fixed clock used by PL011
    try b.beginNode("apb-pclk");
    try b.propString("compatible", "fixed-clock");
    try b.propU32("#clock-cells", 0);
    try b.propU32("clock-frequency", 24_000_000);
    try b.propString("clock-output-names", "clk24mhz");
    try b.propU32("phandle", APB_PCLK_PHANDLE);
    try b.endNode();

    // /pl011@<addr>
    var uart_name_buf: [32]u8 = undefined;
    const uart_name = try std.fmt.bufPrint(&uart_name_buf, "pl011@{x}", .{cfg.uart_base});
    try b.beginNode(uart_name);
    // PL011 driver needs BOTH "arm,pl011" and "arm,primecell" so AMBA bus auto-binds.
    try b.propStringList("compatible", &[_][]const u8{ "arm,pl011", "arm,primecell" });
    try b.propCells("reg", &[_]u32{
        @intCast(cfg.uart_base >> 32),
        @intCast(cfg.uart_base & 0xFFFF_FFFF),
        @intCast(cfg.uart_size >> 32),
        @intCast(cfg.uart_size & 0xFFFF_FFFF),
    });
    // SPI 1, level high (GIC #interrupt-cells=3 → <type, irq, flags>)
    try b.propCells("interrupts", &[_]u32{ 0, 1, 4 });
    // Linux PL011 driver requires clocks
    try b.propCells("clocks", &[_]u32{ APB_PCLK_PHANDLE, APB_PCLK_PHANDLE });
    try b.propStringList("clock-names", &[_][]const u8{ "uartclk", "apb_pclk" });
    try b.endNode();

    try b.endNode(); // root

    return try b.finalize();
}

// ============== Tests ==============

const testing = std.testing;

test "empty DTB has valid header" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    try testing.expectEqual(FDT_MAGIC, h.magic);
    try testing.expectEqual(FDT_VERSION, h.version);
    try testing.expectEqual(FDT_LAST_COMP_VERSION, h.last_comp_version);
    try testing.expectEqual(@as(u32, @intCast(dtb.len)), h.totalsize);
}

test "DTB header offsets are monotonic" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propU32("test", 42);
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    try testing.expect(h.off_mem_rsvmap >= 40); // past header
    try testing.expect(h.off_dt_struct >= h.off_mem_rsvmap);
    try testing.expect(h.off_dt_strings >= h.off_dt_struct);
    try testing.expect(h.totalsize >= h.off_dt_strings);
}

test "mem reserve terminator present" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // No entries added, so only terminator {0,0} = 16 bytes
    try testing.expectEqual(h.off_dt_struct - h.off_mem_rsvmap, 16);
    const addr = std.mem.readInt(u64, dtb[h.off_mem_rsvmap..][0..8], .big);
    const size = std.mem.readInt(u64, dtb[h.off_mem_rsvmap + 8 ..][0..8], .big);
    try testing.expectEqual(@as(u64, 0), addr);
    try testing.expectEqual(@as(u64, 0), size);
}

test "mem reserve with entry" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.addMemReserve(0x48000000, 0x1000);
    try b.beginNode("");
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // 1 entry + terminator = 32 bytes
    try testing.expectEqual(h.off_dt_struct - h.off_mem_rsvmap, 32);
    const addr = std.mem.readInt(u64, dtb[h.off_mem_rsvmap..][0..8], .big);
    const size = std.mem.readInt(u64, dtb[h.off_mem_rsvmap + 8 ..][0..8], .big);
    try testing.expectEqual(@as(u64, 0x48000000), addr);
    try testing.expectEqual(@as(u64, 0x1000), size);
}

test "structure block starts with BEGIN_NODE and ends with FDT_END" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const first_token = std.mem.readInt(u32, dtb[h.off_dt_struct..][0..4], .big);
    try testing.expectEqual(FDT_BEGIN_NODE, first_token);

    const last_token_off = h.off_dt_struct + h.size_dt_struct - 4;
    const last_token = std.mem.readInt(u32, dtb[last_token_off..][0..4], .big);
    try testing.expectEqual(FDT_END, last_token);
}

test "property name stored in strings block" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propU32("compatible", 0); // Will store "compatible" in strings
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // Strings block should contain "compatible\0"
    const s = getString(dtb, h.off_dt_strings, 0);
    try testing.expect(s != null);
    try testing.expectEqualStrings("compatible", s.?);
}

test "string dedup: same property name reuses offset" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propU32("test", 1);
    try b.beginNode("child");
    try b.propU32("test", 2); // same property name
    try b.endNode();
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // Strings block should only contain "test\0" once (5 bytes)
    try testing.expectEqual(@as(u32, 5), h.size_dt_strings);
}

test "propU64 emits 8 bytes big-endian" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propU64("val", 0xDEADBEEF_CAFEBABE);
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // Find PROP token: BEGIN_NODE + pad + PROP + len + nameoff + data
    // BEGIN_NODE(4) + name ""(pad to 4, so 4 bytes) = 8 bytes
    const prop_off = h.off_dt_struct + 8;
    const token = std.mem.readInt(u32, dtb[prop_off..][0..4], .big);
    try testing.expectEqual(FDT_PROP, token);
    const len = std.mem.readInt(u32, dtb[prop_off + 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 8), len);
    // data starts after PROP(4) + len(4) + nameoff(4) = 12 bytes after PROP token
    const hi = std.mem.readInt(u32, dtb[prop_off + 12 ..][0..4], .big);
    const lo = std.mem.readInt(u32, dtb[prop_off + 16 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), hi);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), lo);
}

test "propCells emits array of big-endian u32" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propCells("reg", &[_]u32{ 0x0, 0x40000000, 0x0, 0x2000000 });
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const prop_off = h.off_dt_struct + 8;
    const len = std.mem.readInt(u32, dtb[prop_off + 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 16), len); // 4 cells × 4 bytes
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, dtb[prop_off + 12 ..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x40000000), std.mem.readInt(u32, dtb[prop_off + 16 ..][0..4], .big));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, dtb[prop_off + 20 ..][0..4], .big));
    try testing.expectEqual(@as(u32, 0x2000000), std.mem.readInt(u32, dtb[prop_off + 24 ..][0..4], .big));
}

test "propString has null terminator" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propString("compatible", "arm,virt");
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const prop_off = h.off_dt_struct + 8;
    const len = std.mem.readInt(u32, dtb[prop_off + 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 9), len); // "arm,virt" + null
    const data_off = prop_off + 12;
    try testing.expectEqualStrings("arm,virt", dtb[data_off .. data_off + 8]);
    try testing.expectEqual(@as(u8, 0), dtb[data_off + 8]);
}

test "nested nodes with properties" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("");
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.beginNode("memory@40000000");
    try b.propString("device_type", "memory");
    try b.propCells("reg", &[_]u32{ 0x0, 0x40000000, 0x0, 0x2000000 });
    try b.endNode();
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    try testing.expectEqual(FDT_MAGIC, h.magic);
    // Verify total size sanity
    try testing.expect(dtb.len > 100);
    try testing.expect(dtb.len < 1024);

    // Verify "memory@40000000" appears in the structure block
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];
    const found = std.mem.indexOf(u8, struct_block, "memory@40000000");
    try testing.expect(found != null);

    // Verify "arm" not present (just a sanity check for other tests)
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm") == null);
}

test "alignment: struct block entries are 4-byte aligned" {
    var b = DtbBuilder.init(testing.allocator);
    defer b.deinit();

    try b.beginNode("x");  // 1-char name -> needs 3 bytes padding
    try b.propString("a", "bc");  // 2 bytes + null = 3, needs 1 byte padding
    try b.endNode();

    const dtb = try b.finalize();
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    // Struct block size should be divisible by 4
    try testing.expectEqual(@as(u32, 0), h.size_dt_struct % 4);
}

// ---- ZigVM DTB tests ----

test "buildZigVmDtb produces valid header" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    try testing.expectEqual(FDT_MAGIC, h.magic);
    try testing.expectEqual(@as(u32, @intCast(dtb.len)), h.totalsize);
    try testing.expect(dtb.len > 200); // non-trivial
    try testing.expect(dtb.len < 2048); // still small
}

test "buildZigVmDtb contains expected node names" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];

    try testing.expect(std.mem.indexOf(u8, struct_block, "chosen") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "memory@40000000") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "cpus") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "cpu@0") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "timer") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "pl011@9000000") != null);
}

test "buildZigVmDtb contains compatible strings" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];

    try testing.expect(std.mem.indexOf(u8, struct_block, "zigvm,virt") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm,armv8") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm,armv8-timer") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm,pl011") != null);
}

test "buildZigVmDtb honors custom bootargs" {
    const dtb = try buildZigVmDtb(testing.allocator, .{ .bootargs = "console=ttyAMA0" });
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];

    try testing.expect(std.mem.indexOf(u8, struct_block, "console=ttyAMA0") != null);
}

test "buildZigVmDtb contains GIC node and PSCI" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];
    const strings = dtb[h.off_dt_strings..][0..h.size_dt_strings];

    // Node names + property values → struct block
    try testing.expect(std.mem.indexOf(u8, struct_block, "intc@8000000") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm,cortex-a15-gic") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "psci") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "arm,psci-1.0") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "hvc") != null);
    // Property names → strings block
    try testing.expect(std.mem.indexOf(u8, strings, "interrupt-controller\x00") != null);
}

test "buildZigVmDtb has interrupt-parent referencing GIC" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const strings = dtb[h.off_dt_strings..][0..h.size_dt_strings];

    // strings should contain "interrupt-parent\0"
    try testing.expect(std.mem.indexOf(u8, strings, "interrupt-parent\x00") != null);
    // strings should contain "phandle\0"
    try testing.expect(std.mem.indexOf(u8, strings, "phandle\x00") != null);
}

test "buildZigVmDtb cpu0 has psci enable-method" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const strings = dtb[h.off_dt_strings..][0..h.size_dt_strings];

    // "enable-method" is a property name → strings block
    try testing.expect(std.mem.indexOf(u8, strings, "enable-method\x00") != null);
}

test "buildZigVmDtb has apb-pclk clock node" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const struct_block = dtb[h.off_dt_struct..][0..h.size_dt_struct];
    const strings = dtb[h.off_dt_strings..][0..h.size_dt_strings];

    try testing.expect(std.mem.indexOf(u8, struct_block, "apb-pclk") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "fixed-clock") != null);
    try testing.expect(std.mem.indexOf(u8, struct_block, "clk24mhz") != null);
    // PL011 needs clocks/clock-names properties
    try testing.expect(std.mem.indexOf(u8, strings, "clocks\x00") != null);
    try testing.expect(std.mem.indexOf(u8, strings, "clock-names\x00") != null);
}

test "GIC and apb_pclk phandles are distinct" {
    try testing.expect(GIC_PHANDLE != APB_PCLK_PHANDLE);
    try testing.expectEqual(@as(u32, 1), GIC_PHANDLE);
    try testing.expectEqual(@as(u32, 2), APB_PCLK_PHANDLE);
}

test "buildZigVmDtb default mem_size is 128MB" {
    const cfg = ZigVmDtbConfig{};
    try testing.expectEqual(@as(u64, 0x8000000), cfg.mem_size);
}

test "buildZigVmDtb strings block has no duplicate property names" {
    const dtb = try buildZigVmDtb(testing.allocator, .{});
    defer testing.allocator.free(dtb);

    const h = try parseHeader(dtb);
    const strings = dtb[h.off_dt_strings..][0..h.size_dt_strings];

    // Count occurrences of "compatible\0" — should appear only once even though
    // it's used in multiple nodes (root, cpu, timer, uart)
    var count: usize = 0;
    var i: usize = 0;
    while (i + 11 <= strings.len) : (i += 1) {
        if (std.mem.eql(u8, strings[i..][0..11], "compatible\x00")) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
}
