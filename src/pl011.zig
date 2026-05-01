// PL011 PrimeCell UART emulation.
//
// 参考: ARM DDI 0183 "PrimeCell UART (PL011) Technical Reference Manual"
//
// MMIO offsets:
//   0x000  DR        Data Register (read=RX, write=TX)
//   0x004  RSR/ECR   Receive Status / Error Clear
//   0x018  FR        Flag Register (TXFE/RXFE/BUSY/etc)
//   0x020  ILPR      Reserved
//   0x024  IBRD      Integer Baud Rate Divisor
//   0x028  FBRD      Fractional Baud Rate Divisor
//   0x02C  LCR_H     Line Control
//   0x030  CR        Control Register
//   0x034  IFLS      Interrupt FIFO Level Select
//   0x038  IMSC      Interrupt Mask Set/Clear
//   0x03C  RIS       Raw Interrupt Status
//   0x040  MIS       Masked Interrupt Status
//   0x044  ICR       Interrupt Clear Register
//   0x048  DMACR     DMA Control
//   0xFE0..0xFEC  Peripheral Identification 0..3
//   0xFF0..0xFFC  PrimeCell Identification 0..3

const std = @import("std");

// FR (Flag Register) bits
pub const FR_CTS: u32 = 1 << 0;
pub const FR_DSR: u32 = 1 << 1;
pub const FR_DCD: u32 = 1 << 2;
pub const FR_BUSY: u32 = 1 << 3;
pub const FR_RXFE: u32 = 1 << 4; // RX FIFO empty
pub const FR_TXFF: u32 = 1 << 5; // TX FIFO full
pub const FR_RXFF: u32 = 1 << 6; // RX FIFO full
pub const FR_TXFE: u32 = 1 << 7; // TX FIFO empty
pub const FR_RI: u32 = 1 << 8;

// CR (Control Register) bits
pub const CR_UARTEN: u32 = 1 << 0;
pub const CR_TXE: u32 = 1 << 8;
pub const CR_RXE: u32 = 1 << 9;

// Interrupt bits (RIS/MIS/ICR/IMSC)
pub const INT_RX: u32 = 1 << 4;
pub const INT_TX: u32 = 1 << 5;
pub const INT_RT: u32 = 1 << 6; // receive timeout
pub const INT_FE: u32 = 1 << 7;
pub const INT_PE: u32 = 1 << 8;
pub const INT_BE: u32 = 1 << 9;
pub const INT_OE: u32 = 1 << 10;

// PrimeCell ID hardcoded values for PL011
const PERIPHID: [4]u32 = .{ 0x11, 0x10, 0x14, 0x00 };
const PCELLID: [4]u32 = .{ 0x0D, 0xF0, 0x05, 0xB1 };

pub const Pl011 = struct {
    cr: u32 = 0x300, // TXE | RXE default
    lcr_h: u32 = 0,
    ibrd: u32 = 0,
    fbrd: u32 = 0,
    ifls: u32 = 0x12, // default
    imsc: u32 = 0,
    ris: u32 = 0,
    dmacr: u32 = 0,

    // RX FIFO (ring buffer, 32 bytes)
    rx_buf: [32]u8 = .{0} ** 32,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,

    // Output sink (typically stdout writer)
    out_fn: *const fn (ch: u8) void,

    pub fn init(out_fn: *const fn (ch: u8) void) Pl011 {
        return .{ .out_fn = out_fn };
    }

    pub fn read(self: *Pl011, offset: u32) u32 {
        return switch (offset) {
            0x000 => blk: { // DR (RX)
                if (self.rx_head != self.rx_tail) {
                    const c = self.rx_buf[self.rx_tail];
                    self.rx_tail = (self.rx_tail + 1) % @as(u8, @intCast(self.rx_buf.len));
                    if (self.rx_head == self.rx_tail) {
                        // Now empty; clear RX RIS bit
                        self.ris &= ~INT_RX;
                    }
                    break :blk c;
                }
                break :blk 0;
            },
            0x018 => self.flagRegister(),
            0x024 => self.ibrd,
            0x028 => self.fbrd,
            0x02C => self.lcr_h,
            0x030 => self.cr,
            0x034 => self.ifls,
            0x038 => self.imsc,
            0x03C => self.ris,
            0x040 => self.ris & self.imsc, // MIS
            0x048 => self.dmacr,
            0xFE0 => PERIPHID[0],
            0xFE4 => PERIPHID[1],
            0xFE8 => PERIPHID[2],
            0xFEC => PERIPHID[3],
            0xFF0 => PCELLID[0],
            0xFF4 => PCELLID[1],
            0xFF8 => PCELLID[2],
            0xFFC => PCELLID[3],
            else => 0,
        };
    }

    pub fn write(self: *Pl011, offset: u32, value: u32) void {
        switch (offset) {
            0x000 => { // DR (TX)
                self.out_fn(@intCast(value & 0xFF));
            },
            0x024 => self.ibrd = value,
            0x028 => self.fbrd = value,
            0x02C => self.lcr_h = value,
            0x030 => self.cr = value,
            0x034 => self.ifls = value,
            0x038 => self.imsc = value & 0x7FF,
            0x044 => {
                self.ris &= ~(value & 0x7FF); // ICR clear
                // RX/RT are level-triggered: re-assert if buffer still has data
                if (self.rx_head != self.rx_tail) {
                    self.ris |= INT_RX | INT_RT;
                }
            },
            0x048 => self.dmacr = value,
            else => {},
        }
    }

    fn flagRegister(self: *const Pl011) u32 {
        var fr: u32 = 0;
        if (self.rx_head == self.rx_tail) fr |= FR_RXFE;
        fr |= FR_TXFE; // TX always empty (synchronous output)
        return fr;
    }

    // Push a char into RX FIFO (called from external input source).
    // Sets both RX (level-met) and RT (receive timeout) so the driver fires
    // even with FIFO mode + threshold-based IRQ enabled.
    pub fn pushRxChar(self: *Pl011, c: u8) void {
        const buf_len: u8 = @intCast(self.rx_buf.len);
        const next = (self.rx_head + 1) % buf_len;
        if (next == self.rx_tail) return; // FIFO full, drop char
        self.rx_buf[self.rx_head] = c;
        self.rx_head = next;
        self.ris |= INT_RX | INT_RT;
    }

    // Whether RX IRQ should be asserted (RX or RT bit set in RIS&IMSC)
    pub fn rxIrqPending(self: *const Pl011) bool {
        return (self.ris & self.imsc & (INT_RX | INT_RT)) != 0;
    }
};

// ============== Tests ==============

const testing = std.testing;

var test_buf: [256]u8 = undefined;
var test_buf_len: usize = 0;

fn testOut(c: u8) void {
    if (test_buf_len < test_buf.len) {
        test_buf[test_buf_len] = c;
        test_buf_len += 1;
    }
}

fn resetTestBuf() void {
    test_buf_len = 0;
}

test "DR write outputs to sink" {
    resetTestBuf();
    var u = Pl011.init(testOut);
    u.write(0x000, 'H');
    u.write(0x000, 'i');
    try testing.expectEqualStrings("Hi", test_buf[0..test_buf_len]);
}

test "FR shows TXFE always set, RXFE when no input" {
    var u = Pl011.init(testOut);
    const fr_empty = u.read(0x018);
    try testing.expect((fr_empty & FR_TXFE) != 0);
    try testing.expect((fr_empty & FR_RXFE) != 0);

    u.pushRxChar('A');
    const fr_with_rx = u.read(0x018);
    try testing.expect((fr_with_rx & FR_TXFE) != 0);
    try testing.expect((fr_with_rx & FR_RXFE) == 0);
}

test "DR read returns RX char then 0" {
    var u = Pl011.init(testOut);
    u.pushRxChar('Z');
    try testing.expectEqual(@as(u32, 'Z'), u.read(0x000));
    try testing.expectEqual(@as(u32, 0), u.read(0x000));
}

test "PeriphID and PCellID return PL011 magic" {
    var u = Pl011.init(testOut);
    try testing.expectEqual(@as(u32, 0x11), u.read(0xFE0));
    try testing.expectEqual(@as(u32, 0x10), u.read(0xFE4));
    try testing.expectEqual(@as(u32, 0x14), u.read(0xFE8));
    try testing.expectEqual(@as(u32, 0x00), u.read(0xFEC));
    try testing.expectEqual(@as(u32, 0x0D), u.read(0xFF0));
    try testing.expectEqual(@as(u32, 0xF0), u.read(0xFF4));
    try testing.expectEqual(@as(u32, 0x05), u.read(0xFF8));
    try testing.expectEqual(@as(u32, 0xB1), u.read(0xFFC));
}

test "control/baud registers read back" {
    var u = Pl011.init(testOut);
    u.write(0x024, 0x40); // IBRD
    u.write(0x028, 0x05); // FBRD
    u.write(0x02C, 0x70); // LCR_H
    u.write(0x030, 0x301); // CR
    try testing.expectEqual(@as(u32, 0x40), u.read(0x024));
    try testing.expectEqual(@as(u32, 0x05), u.read(0x028));
    try testing.expectEqual(@as(u32, 0x70), u.read(0x02C));
    try testing.expectEqual(@as(u32, 0x301), u.read(0x030));
}

test "IMSC + ICR for interrupt control" {
    var u = Pl011.init(testOut);
    u.write(0x038, INT_RX); // IMSC: enable RX IRQ
    try testing.expectEqual(INT_RX, u.read(0x038));

    u.pushRxChar('a');
    try testing.expect(u.rxIrqPending()); // RIS&IMSC has RX

    // MIS = RIS & IMSC (also has INT_RT now)
    try testing.expect((u.read(0x040) & INT_RX) != 0);

    // ICR with empty buffer fully clears the bit
    _ = u.read(0x000); // drain DR
    u.write(0x044, INT_RX | INT_RT);
    try testing.expect(!u.rxIrqPending());
}

test "ICR re-asserts RX/RT if buffer still has data (level-triggered)" {
    var u = Pl011.init(testOut);
    u.write(0x038, INT_RX); // IMSC enable RX
    u.pushRxChar('x');
    u.pushRxChar('y');
    try testing.expect(u.rxIrqPending());
    // ICR clears, but buffer still has 'x','y' → RX/RT re-asserted
    u.write(0x044, INT_RX | INT_RT);
    try testing.expect(u.rxIrqPending());
}

test "rxIrqPending requires both RIS and IMSC" {
    var u = Pl011.init(testOut);
    u.pushRxChar('x');
    // IMSC=0 → no IRQ even though RIS has the bit
    try testing.expect(!u.rxIrqPending());
    u.write(0x038, INT_RX);
    try testing.expect(u.rxIrqPending());
}

test "unknown offsets return 0 / are ignored" {
    var u = Pl011.init(testOut);
    try testing.expectEqual(@as(u32, 0), u.read(0x100));
    u.write(0x100, 0xDEADBEEF); // shouldn't crash
}

test "DR read clears RX RIS bit" {
    var u = Pl011.init(testOut);
    u.write(0x038, INT_RX);
    u.pushRxChar('y');
    try testing.expect(u.rxIrqPending());
    _ = u.read(0x000); // read DR
    try testing.expect(!u.rxIrqPending());
}

test "RX ring buffer FIFO order" {
    var u = Pl011.init(testOut);
    u.pushRxChar('h');
    u.pushRxChar('i');
    u.pushRxChar('!');
    try testing.expectEqual(@as(u32, 'h'), u.read(0x000));
    try testing.expectEqual(@as(u32, 'i'), u.read(0x000));
    try testing.expectEqual(@as(u32, '!'), u.read(0x000));
    try testing.expectEqual(@as(u32, 0), u.read(0x000)); // empty
}

test "RX ring buffer drops on overflow" {
    var u = Pl011.init(testOut);
    // push 33 chars (buffer is 32, one slot reserved for empty/full distinction)
    for (0..33) |i| {
        u.pushRxChar(@intCast('A' + (i % 26)));
    }
    // Read all available; should be at most 31 chars (len - 1 due to ring buffer convention)
    var count: usize = 0;
    while (true) {
        const c = u.read(0x000);
        if (c == 0) break;
        count += 1;
        if (count > 50) return error.TooMany; // safety
    }
    try testing.expect(count >= 30 and count <= 32);
}

test "RX FR bit stays clear while data available" {
    var u = Pl011.init(testOut);
    u.pushRxChar('a');
    u.pushRxChar('b');
    // RXFE clear after first push
    try testing.expect((u.read(0x018) & FR_RXFE) == 0);
    _ = u.read(0x000); // read 'a'
    // Still has 'b'
    try testing.expect((u.read(0x018) & FR_RXFE) == 0);
    _ = u.read(0x000); // read 'b'
    // Now empty
    try testing.expect((u.read(0x018) & FR_RXFE) != 0);
}
