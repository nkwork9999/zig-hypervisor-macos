# ZigVM ⚡️

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)

A lightweight ARM64 Virtual Machine Monitor (VMM) written in Zig, utilizing the Apple **Hypervisor.framework** on macOS (Apple Silicon).

This project demonstrates how to boot a minimal Linux-like payload directly by interacting with low-level Hypervisor APIs, handling MMIO, and generating Device Trees dynamically.

## ✨ Features

- **Apple Silicon Native**: Runs directly on M1/M2/M3 chips using `Hypervisor.framework`.
- **Zero Dependencies**: Pure Zig implementation with direct extern function bindings.
- **Boot Protocol**: Implements the ARM64 Linux Boot Protocol.
- **Hardware Emulation**:
  - [x] PL011 UART (Text Output)
  - [x] MMIO Handling (Data Abort)
  - [x] GIC / Exception Vector Table (VBAR_EL1)
  - [x] Virtual Timer (vTimer)
  - [x] Device Tree Blob (DTB) Generation

## 🚀 Usage

### Prerequisites

- macOS (Apple Silicon)
- Zig (latest)

### Build & Run

Since macOS requires the `com.apple.security.hypervisor` entitlement to access virtualization APIs, you must sign the binary after building.

```bash
# 1. Build
zig build

# 2. Sign with entitlements (Required!)
codesign -s - --entitlements entitlements.plist -f zig-out/bin/zigvm

# 3. Run
./zig-out/bin/zigvm
```
