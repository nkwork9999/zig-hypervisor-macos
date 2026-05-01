// GICv2 (Generic Interrupt Controller v2) MMIO emulation.
//
// 参考: ARM IHI 0048B.b "ARM Generic Interrupt Controller Architecture Specification, version 2.0"
//
// GICD (Distributor) MMIO offsets:
//   0x000  CTLR        Distributor control
//   0x004  TYPER       Type (read-only)
//   0x008  IIDR        Implementer ID (read-only)
//   0x100  ISENABLER0  Interrupt Set-Enable bits (1 bit per IRQ)
//   0x180  ICENABLER0  Interrupt Clear-Enable bits
//   0x200  ISPENDR0    Interrupt Set-Pending bits
//   0x280  ICPENDR0    Interrupt Clear-Pending bits
//   0x400  IPRIORITYR  Interrupt Priority (1 byte per IRQ)
//   0x800  ITARGETSR   Interrupt Target (1 byte per IRQ)
//   0xC00  ICFGR       Interrupt Configuration (2 bits per IRQ)
//
// GICC (CPU Interface) MMIO offsets:
//   0x000  CTLR        CPU Interface control
//   0x004  PMR         Priority Mask (only IRQs of strictly higher priority - i.e. lower numeric - than this fire)
//   0x00C  IAR         Interrupt Acknowledge (read-only — returns pending IRQ ID, marks active)
//   0x010  EOIR        End of Interrupt (write-only — clears active)

const std = @import("std");

pub const NUM_IRQS: u32 = 1024; // GIC supports up to 1020 IRQs
pub const SPURIOUS_IRQ: u32 = 1023;

pub const Gic = struct {
    // GICD state
    dist_ctlr: u32 = 0,
    enabled: [NUM_IRQS / 32]u32 = .{0} ** (NUM_IRQS / 32),
    pending: [NUM_IRQS / 32]u32 = .{0} ** (NUM_IRQS / 32),
    active: [NUM_IRQS / 32]u32 = .{0} ** (NUM_IRQS / 32),
    priority: [NUM_IRQS]u8 = .{0xA0} ** NUM_IRQS,
    target: [NUM_IRQS]u8 = .{0x01} ** NUM_IRQS,

    // GICC state
    cpu_ctlr: u32 = 0,
    priority_mask: u32 = 0,

    // ----- Distributor handlers -----

    pub fn distRead(self: *Gic, offset: u32) u32 {
        return switch (offset) {
            0x000 => self.dist_ctlr,
            // TYPER: lower 5 bits = ITLinesNumber. We support 1024 IRQs → 32 (= 1024/32 - 1)
            0x004 => 0x1F,
            0x008 => 0x0001_43B, // IIDR: stub (vendor=0x43B = ARM, variant=0, revision=0, product=0x0001)
            else => blk: {
                // ISENABLER (0x100..0x17F)
                if (offset >= 0x100 and offset < 0x180) {
                    const n = (offset - 0x100) / 4;
                    if (n < self.enabled.len) break :blk self.enabled[n];
                    break :blk 0;
                }
                // ICENABLER (0x180..0x1FF) — reads same as ISENABLER
                if (offset >= 0x180 and offset < 0x200) {
                    const n = (offset - 0x180) / 4;
                    if (n < self.enabled.len) break :blk self.enabled[n];
                    break :blk 0;
                }
                // IPRIORITYR (0x400..0x7FF) — 1 byte per IRQ packed into u32 reads
                if (offset >= 0x400 and offset < 0x800) {
                    const base = (offset - 0x400);
                    if (base + 4 > NUM_IRQS) break :blk 0;
                    var v: u32 = 0;
                    for (0..4) |i| v |= @as(u32, self.priority[base + i]) << @intCast(i * 8);
                    break :blk v;
                }
                // ITARGETSR (0x800..0xBFF) — 1 byte per IRQ
                if (offset >= 0x800 and offset < 0xC00) {
                    const base = (offset - 0x800);
                    if (base + 4 > NUM_IRQS) break :blk 0;
                    var v: u32 = 0;
                    for (0..4) |i| v |= @as(u32, self.target[base + i]) << @intCast(i * 8);
                    break :blk v;
                }
                break :blk 0;
            },
        };
    }

    pub fn distWrite(self: *Gic, offset: u32, value: u32) void {
        switch (offset) {
            0x000 => self.dist_ctlr = value & 0x3,
            else => {
                // ISENABLER (0x100..0x17F) — set bits
                if (offset >= 0x100 and offset < 0x180) {
                    const n = (offset - 0x100) / 4;
                    if (n < self.enabled.len) self.enabled[n] |= value;
                    return;
                }
                // ICENABLER (0x180..0x1FF) — clear bits
                if (offset >= 0x180 and offset < 0x200) {
                    const n = (offset - 0x180) / 4;
                    if (n < self.enabled.len) self.enabled[n] &= ~value;
                    return;
                }
                // ISPENDR (0x200..0x27F) — set pending
                if (offset >= 0x200 and offset < 0x280) {
                    const n = (offset - 0x200) / 4;
                    if (n < self.pending.len) self.pending[n] |= value;
                    return;
                }
                // ICPENDR (0x280..0x2FF) — clear pending
                if (offset >= 0x280 and offset < 0x300) {
                    const n = (offset - 0x280) / 4;
                    if (n < self.pending.len) self.pending[n] &= ~value;
                    return;
                }
                // IPRIORITYR (0x400..0x7FF)
                if (offset >= 0x400 and offset < 0x800) {
                    const base = offset - 0x400;
                    if (base + 4 <= NUM_IRQS) {
                        for (0..4) |i| self.priority[base + i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
                    }
                    return;
                }
                // ITARGETSR (0x800..0xBFF)
                if (offset >= 0x800 and offset < 0xC00) {
                    const base = offset - 0x800;
                    if (base + 4 <= NUM_IRQS) {
                        for (0..4) |i| self.target[base + i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
                    }
                    return;
                }
                // ICFGR — ignored (we treat all as level)
            },
        }
    }

    // ----- CPU Interface handlers -----

    pub fn cpuRead(self: *Gic, offset: u32) u32 {
        return switch (offset) {
            0x000 => self.cpu_ctlr,
            0x004 => self.priority_mask,
            0x00C => self.acknowledge(), // IAR
            else => 0,
        };
    }

    pub fn cpuWrite(self: *Gic, offset: u32, value: u32) void {
        switch (offset) {
            0x000 => self.cpu_ctlr = value & 0x3,
            0x004 => self.priority_mask = value & 0xFF,
            0x010 => self.endOfInterrupt(value & 0x3FF), // EOIR
            else => {},
        }
    }

    // ----- IRQ delivery -----

    // Mark IRQ as pending; returns true if it should be delivered to vcpu now.
    pub fn assertIrq(self: *Gic, irq: u32) bool {
        if (irq >= NUM_IRQS) return false;
        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);
        self.pending[word] |= bit;
        return self.shouldDeliver();
    }

    pub fn isIrqEnabled(self: *const Gic, irq: u32) bool {
        if (irq >= NUM_IRQS) return false;
        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);
        return (self.enabled[word] & bit) != 0;
    }

    pub fn isIrqPending(self: *const Gic, irq: u32) bool {
        if (irq >= NUM_IRQS) return false;
        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);
        return (self.pending[word] & bit) != 0;
    }

    // Highest-priority enabled+pending+priority-passing IRQ, or null
    pub fn highestPending(self: *const Gic) ?u32 {
        if ((self.dist_ctlr & 1) == 0) return null;
        if ((self.cpu_ctlr & 1) == 0) return null;
        // Linear scan; pick lowest IRQ ID with valid priority among enabled+pending
        var best: ?u32 = null;
        var best_prio: u32 = 0xFF;
        var irq: u32 = 0;
        while (irq < NUM_IRQS) : (irq += 1) {
            if (!self.isIrqPending(irq)) continue;
            if (!self.isIrqEnabled(irq)) continue;
            const p: u32 = self.priority[irq];
            if (p >= self.priority_mask) continue; // priority must be < PMR
            if (best == null or p < best_prio) {
                best = irq;
                best_prio = p;
            }
        }
        return best;
    }

    pub fn shouldDeliver(self: *const Gic) bool {
        return self.highestPending() != null;
    }

    // GICC_IAR read: get pending IRQ, mark active, clear pending
    pub fn acknowledge(self: *Gic) u32 {
        const irq = self.highestPending() orelse return SPURIOUS_IRQ;
        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);
        self.pending[word] &= ~bit;
        self.active[word] |= bit;
        return irq;
    }

    // GICC_EOIR write: clear active for the given IRQ
    pub fn endOfInterrupt(self: *Gic, irq: u32) void {
        if (irq >= NUM_IRQS) return;
        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);
        self.active[word] &= ~bit;
    }
};

// ============== Tests ==============

const testing = std.testing;

test "default state is disabled" {
    var gic: Gic = .{};
    try testing.expectEqual(@as(u32, 0), gic.dist_ctlr);
    try testing.expectEqual(@as(u32, 0), gic.cpu_ctlr);
    try testing.expect(!gic.shouldDeliver());
    try testing.expectEqual(@as(u32, SPURIOUS_IRQ), gic.acknowledge());
}

test "TYPER/IIDR are read-only stubs" {
    var gic: Gic = .{};
    try testing.expectEqual(@as(u32, 0x1F), gic.distRead(0x004));
    try testing.expect(gic.distRead(0x008) != 0);
}

test "distributor enable bit" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    try testing.expectEqual(@as(u32, 1), gic.dist_ctlr);
    try testing.expectEqual(@as(u32, 1), gic.distRead(0x000));
}

test "ISENABLER sets bits, ICENABLER clears" {
    var gic: Gic = .{};
    // Enable IRQ 27 → bit 27 of ISENABLER0
    gic.distWrite(0x100, 1 << 27);
    try testing.expect(gic.isIrqEnabled(27));
    try testing.expect(!gic.isIrqEnabled(28));
    // Read back
    try testing.expectEqual(@as(u32, 1 << 27), gic.distRead(0x100));

    // Clear IRQ 27 via ICENABLER
    gic.distWrite(0x180, 1 << 27);
    try testing.expect(!gic.isIrqEnabled(27));
}

test "ISENABLER for IRQ 64 lands in word 2" {
    var gic: Gic = .{};
    gic.distWrite(0x108, 1); // ISENABLER2 (offset 0x100 + 2*4)
    try testing.expect(gic.isIrqEnabled(64));
}

test "priority register packing" {
    var gic: Gic = .{};
    // Write priority for IRQs 0..3
    gic.distWrite(0x400, 0x40_30_20_10);
    try testing.expectEqual(@as(u8, 0x10), gic.priority[0]);
    try testing.expectEqual(@as(u8, 0x20), gic.priority[1]);
    try testing.expectEqual(@as(u8, 0x30), gic.priority[2]);
    try testing.expectEqual(@as(u8, 0x40), gic.priority[3]);
    try testing.expectEqual(@as(u32, 0x40_30_20_10), gic.distRead(0x400));
}

test "PMR mask" {
    var gic: Gic = .{};
    gic.cpuWrite(0x004, 0xF8);
    try testing.expectEqual(@as(u32, 0xF8), gic.priority_mask);
    try testing.expectEqual(@as(u32, 0xF8), gic.cpuRead(0x004));
}

test "shouldDeliver requires both distributor + CPU + enabled + pending + priority" {
    var gic: Gic = .{};
    // Setup IRQ 27, priority 0x80
    gic.priority[27] = 0x80;

    // No distributor enable → no delivery
    _ = gic.assertIrq(27);
    try testing.expect(!gic.shouldDeliver());

    // Enable distributor — still no CPU
    gic.distWrite(0x000, 1);
    try testing.expect(!gic.shouldDeliver());

    // Enable CPU — still need ISENABLER and PMR
    gic.cpuWrite(0x000, 1);
    try testing.expect(!gic.shouldDeliver());

    // Enable IRQ 27
    gic.distWrite(0x100, 1 << 27);
    // PMR = 0 → priority 0x80 not allowed (< 0)
    try testing.expect(!gic.shouldDeliver());

    // PMR = 0xFF → priority 0x80 < 0xFF → allowed
    gic.cpuWrite(0x004, 0xFF);
    try testing.expect(gic.shouldDeliver());
}

test "IAR/EOIR cycle" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    gic.cpuWrite(0x000, 1);
    gic.cpuWrite(0x004, 0xFF);
    gic.distWrite(0x100, 1 << 27); // enable IRQ 27
    gic.priority[27] = 0x80;
    _ = gic.assertIrq(27);
    try testing.expect(gic.isIrqPending(27));

    // Acknowledge — should return 27, mark active, clear pending
    const ack = gic.acknowledge();
    try testing.expectEqual(@as(u32, 27), ack);
    try testing.expect(!gic.isIrqPending(27));
    // After ack: shouldDeliver = false (pending cleared)
    try testing.expect(!gic.shouldDeliver());

    // EOI for 27 → clears active
    gic.endOfInterrupt(27);
}

test "spurious IRQ when nothing pending" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    gic.cpuWrite(0x000, 1);
    try testing.expectEqual(@as(u32, SPURIOUS_IRQ), gic.acknowledge());
}

test "highest priority wins" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    gic.cpuWrite(0x000, 1);
    gic.cpuWrite(0x004, 0xFF);
    gic.distWrite(0x100, (1 << 27) | (1 << 30)); // enable both
    gic.priority[27] = 0xA0;
    gic.priority[30] = 0x40; // lower numeric = higher priority
    _ = gic.assertIrq(27);
    _ = gic.assertIrq(30);
    try testing.expectEqual(@as(?u32, 30), gic.highestPending());
    // Acknowledge takes #30 first
    try testing.expectEqual(@as(u32, 30), gic.acknowledge());
    try testing.expectEqual(@as(u32, 27), gic.acknowledge());
}

test "PMR blocks low-priority IRQs" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    gic.cpuWrite(0x000, 1);
    gic.cpuWrite(0x004, 0x80); // PMR = 0x80
    gic.distWrite(0x100, 1 << 27);
    gic.priority[27] = 0xA0; // 0xA0 > 0x80 → blocked
    _ = gic.assertIrq(27);
    try testing.expect(!gic.shouldDeliver());

    // Lower IRQ priority below PMR
    gic.priority[27] = 0x40;
    try testing.expect(gic.shouldDeliver());
}

test "ICPENDR clears pending" {
    var gic: Gic = .{};
    gic.distWrite(0x000, 1);
    gic.cpuWrite(0x000, 1);
    gic.distWrite(0x100, 1 << 27);
    _ = gic.assertIrq(27);
    try testing.expect(gic.isIrqPending(27));
    gic.distWrite(0x280, 1 << 27); // ICPENDR
    try testing.expect(!gic.isIrqPending(27));
}

test "MMIO offsets for ITARGETSR" {
    var gic: Gic = .{};
    gic.distWrite(0x800, 0x04_03_02_01);
    try testing.expectEqual(@as(u8, 0x01), gic.target[0]);
    try testing.expectEqual(@as(u8, 0x04), gic.target[3]);
    try testing.expectEqual(@as(u32, 0x04_03_02_01), gic.distRead(0x800));
}
