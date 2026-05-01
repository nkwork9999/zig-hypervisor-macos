# ZigVM ⚡️

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)

純Zigで書かれた **Apple Silicon 向け ARM64 ハイパーバイザ**。
macOS の `Hypervisor.framework` を直接叩き、本物の Linux カーネルをブートして対話シェルまで到達する。

```
╔════════════════════════════════════════════════╗
║          Z I G   V M                           ║
║  ───────────────────────────────────────────   ║
║  pure-Zig ARM64 hypervisor on Apple Silicon    ║
║  running Alpine Linux 6.12 / busybox           ║
╚════════════════════════════════════════════════╝
~ # uname -a
Linux (none) 6.12.81-0-virt #1-Alpine SMP PREEMPT_DYNAMIC aarch64 Linux
~ # ls /
bin   dev   etc   init   lib   media   newroot   proc   root   run   sbin   sys   usr   var
~ # echo HELLO_FROM_ZIGVM_LINUX
HELLO_FROM_ZIGVM_LINUX
~ # exit
```

## ✨ 特徴

- **純 Zig 実装** (~2,800 行のコア + ~1,140 行のテスト)
- **外部依存ゼロ** — `Hypervisor.framework` を `extern` で直接呼ぶ
- **本物の Linux 6.12 が動く** (Alpine aarch64)
- **対話的 busybox シェル** — 入力可、ANSI カラー対応
- **103 ユニットテスト** — 純粋ロジックは Hypervisor.framework なしで全テスト
- **ハードウェアエミュレーション**:
  - [x] PL011 PrimeCell UART (RX/TX/IMSC/ICR/PrimeCell ID)
  - [x] GICv2 (Distributor + CPU Interface)
  - [x] PSCI 1.1 (HVC ハイパーバイザコール)
  - [x] vTimer (Apple HV 経由で IRQ 27 配信)
  - [x] Flattened Device Tree (DTB) 動的生成
  - [x] ARM64 Linux Image / ELF カーネルローダー

## 🚀 使い方

### 必要環境

- macOS (Apple Silicon: M1/M2/M3 以降)
- Zig 0.15.2 以降

### ビルドと実行

```bash
# 1. ビルド
zig build

# 2. Hypervisor entitlement を codesign
codesign -s - --entitlements entitlements.plist -f zig-out/bin/zigvm

# 3a. 自作 mini OS (zigos) を起動
./zig-out/bin/zigvm

# 3b. 本物の Alpine Linux を起動
./zig-out/bin/zigvm /path/to/Image-alpine /path/to/initramfs

# 4. テスト
zig build test
```

## 🏗️ アーキテクチャ

```
┌─────────────────────────────────────────────┐
│             zigvm (host: macOS)             │
│  ┌──────────────────────────────────────┐   │
│  │ main.zig — VMM main loop             │   │
│  │  ・ ELF / Image kernel loader        │   │
│  │  ・ exit reason dispatch             │   │
│  │  ・ stdin → PL011 RX 配線            │   │
│  └──────────────────────────────────────┘   │
│       ↓ MMIO trap routing                   │
│  ┌────────┐  ┌────────┐  ┌────────┐         │
│  │ pl011  │  │ gic v2 │  │ dtb    │         │
│  │ UART   │  │ + IRQ  │  │ FDT    │         │
│  └────────┘  └────────┘  └────────┘         │
│       ↓ Apple Hypervisor.framework          │
│  ┌──────────────────────────────────────┐   │
│  │ Guest (EL1)                          │   │
│  │  Linux 6.12 / Alpine / busybox sh    │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

| ファイル | 行数 | 内容 |
|---|---:|---|
| [src/main.zig](src/main.zig) | 571 | VMM main、exit reason 処理、stdin 配線 |
| [src/hv.zig](src/hv.zig) | 70 | Hypervisor.framework C bindings + 定数 |
| [src/dtb.zig](src/dtb.zig) | 797 | Flattened Device Tree ビルダー (+23 tests) |
| [src/gic.zig](src/gic.zig) | 387 | GICv2 MMIO エミュ (+14 tests) |
| [src/pl011.zig](src/pl011.zig) | 321 | PL011 UART エミュ (+13 tests) |
| [src/vmcore.zig](src/vmcore.zig) | 854 | 純粋ロジック (ELF, syndrome, 命令エンコード) (+53 tests) |

### ゲストのメモリマップ

```
0x08000000 - 0x08010000  GICD (Distributor)
0x08010000 - 0x08020000  GICC (CPU Interface)
0x09000000 - 0x09001000  PL011 UART
0x09001000 -             TIMER_SLEEP MMIO (zigos用、Linux未使用)
0x40000000 - 0x60000000  RAM (512MB)
0x44000000 - 0x44000540  DTB (Flattened Device Tree)
0x45000000 -             initramfs (gzip cpio)
```

## 📜 開発フェーズ / バージョン履歴

### Phase 0: 基盤整備
- 自己完結デモ 4 種 (algorithm / loop / interactive UART / vTimer)
- vmcore.zig に純粋ロジック集約、テスト 21 件追加
- ✅ HV計算・命令エンコード・syndrome解析の検証

### Phase 1: メモリ拡張 + Image ローダー
- ゲストメモリ 2MB → 128MB → 512MB
- ARM64 Linux Image format (`ARM\x64` magic offset 56) ローダー追加
- DTB に `interrupt-parent`, GIC ノード, PSCI ノード追加

### Phase 2: PSCI (HVC ハイパーバイザコール)
- `EC_HVC = 0x16` トラップ処理
- `PSCI_VERSION` (0x84000000) → 1.1 を返す
- `PSCI_SYSTEM_OFF` (0x84000008) → VM 終了
- 🐛 ハマり所: HVC は `ELR_EL2` が PC+4 自動設定。VMM で `set_reg(PC, pc+4)` してはいけない

### Phase 3: GICv2 MMIO エミュレーション
- `src/gic.zig` 新設 (~387行 + 14 tests)
- CTLR / TYPER / ISENABLER / ICENABLER / ISPENDR / IPRIORITYR / ITARGETSR + GICC レジスタ
- vTimer (PPI 11 → IRQ 27) GIC 経由配信、Linux scheduler tick 動作

### Phase 4: PL011 完全 UART
- DR / FR / CR / LCR_H / IBRD / FBRD / IFLS / IMSC / RIS / MIS / ICR
- PrimeCell ID (0xFE0–0xFEC) と PCell ID (0xFF0–0xFFC) で Linux PL011 driver の probe が成功
- ✅ 9 tests 追加

### Phase 5: EL1 直接ブート検証
- DTB に `apb_pclk` 24MHz fixed-clock 追加 (PL011 が要求)
- `x1..x7 = 0` 明示クリア (Linux boot protocol 準拠)
- `CurrentEL=4 (EL1)`, `CNTFRQ_EL0=24MHz`, `MIDR_EL1`, `ID_AA64MMFR0_EL1` が EL1 で trap なしで読める

### Phase 6: 本物の Linux 起動 + 対話シェル ⭐
- Alpine Linux 6.12 (vmlinuz-virt + initramfs-virt) ブート
- 自作 init script で busybox shell `~ #` プロンプトまで到達
- **stdin RX 配線**: `posix.read` non-blocking + raw termios → `pl011.pushRxChar` → 毎ループ `gic.assertIrq(33)` → `set_pending_interrupt`
- **対話可能**: `pwd`, `ls`, `echo`, `uname`, `free`, `uptime`, `exit` — ANSI カラー対応

#### 🐛 致命的だったバグ 5 つ

1. **`HV_REG_CPSR` の値**: `hv_reg_t` enum で CPSR は **34** (32 ではない)。32 を使うと FPCR に書き込んでしまい、CPSR がデフォルトのままで DAIF マスクが予測不能に
2. **DTB PL011 compatible**: `<"arm,pl011", "arm,primecell">` の StringList **両方必須**。`arm,primecell` がないと AMBA bus が auto-bind せず `/dev/ttyAMA0` が登録されない
3. **vtimer_mask 初期値**: `true` で起動すると Linux scheduler tick が完全停止。`false` に設定し、`GICC_EOIR` で IRQ 27 受信時に再 `false` にする必要
4. **SPI ID off-by-one**: DT `interrupts = <0 1 4>` の SPI 1 は GIC IRQ ID **33** (`32 + 1`)。SPI ベースが 32 なので「最初の SPI = IRQ 32」「2 番目 = IRQ 33」
5. **PL011 ICR の level-triggered 再 assert**: Linux は probe 時に `ICR = 0xFFFF` で全 RIS クリア。RX バッファに data が残っていれば RX/RT bit を再 assert する必要 (level-triggered)

### Phase 7: 改良
- WFI/WFE トラップを `nanosleep(1ms)` に置換 → host CPU 100% 回避 (idle時ほぼ0%)
- `quiet loglevel=3` で kernel boot メッセージを抑制
- ASCII art バナー付き init script

### Phase 8: framebuffer + macOS ウィンドウ (部分達成)
- DTB に `simple-framebuffer` ノード追加 (1024×768 BGRA at 0x50000000)
- Linux RAM を 256MB に縮め、その上 (0x50000000+) を FB 専用領域として hv_vm_map
- VMM が **`zigvm-viewer`** (SDL2 ベースの別バイナリ) を subprocess として起動
- 別スレッドで guest framebuffer メモリを 30fps で viewer の stdin にパイプ
- viewer は SDL2 で window 描画 + キーボードイベントを stdout で zigvm に返す
- zigvm 側で受け取ったキーバイトを PL011 RX FIFO へ push (= 普通のシリアル入力扱い)
- `ZIGVM_DISPLAY=1 ./zig-out/bin/zigvm Image initramfs` で macOS ウィンドウ表示

#### 最終達成状態
- ✅ **ウィンドウ表示**: kernel printk が fbcon 経由で window に描画される
- ✅ **キー入力配線**: viewer 上で打鍵 → SDL → pipe → PL011 RX → ttyAMA0 へ届く
- ✅ **ターミナル経由 shell**: PL011 (host stdout/stdin) で対話 shell 動作

#### ⚠️ 詰み: window で打鍵 → fbcon shell が echo されない
1. simpledrm を modprobe ロードすると fbcon takeover ✓
2. その直後 kernel が **soft lockup**: `watchdog: BUG: soft lockup - CPU#0 stuck for 22s`
3. /init の続き (`exec /bin/sh -i`) まで到達できず shell 起動せず
4. キー入力は流れるが受け手 (shell) が居ない

**根因推定**: 我々の最小 GICv2 + WFI/SDL/IRQ ハンドリングが simpledrm の DRM 初期化シーケンスでデッドロック。深掘り未実施。

#### Window で実用 shell に必要な追加実装

| 方針 | 規模 | 状況 |
|---|---|---|
| simpledrm hang の解明 (GIC 精密化, WFI semantics) | 中-大 | 未調査 |
| VirtIO-input 実装 → fbcon shell に直接 keystroke | 中 | 未着手 |
| VirtIO-GPU 実装 (simpledrm の代替) | 数千行 | 未着手 |
| VirtIO Net + SSH 接続 | 中-大 | 未着手 |

#### 現実的な使い方
- `./zig-out/bin/zigvm Image initramfs` (display なし) → ターミナル対話 shell
- 既存 GUI Linux ツール (UTM/Lima) は数十万行越え。本プロジェクトは "純Zig + 最小実装" の枠で完了とする。

### コード整理
- `src/hv.zig` 新設し、Hypervisor.framework extern 宣言 + HV/EC/PSCI 定数を集約
- `src/main copy.zig` と Zig テンプレート残骸 `src/root.zig` を削除
- `build.zig` を 203 → 62 行に短縮
- バイナリ名を `_202512zigvm` → `zigvm` に改名

## 🎬 4 つの自己完結デモ

| デモ | 内容 |
|---|---|
| `zig build demo_a` | ゲストが `1 + 2 + … + 10 = 55` を計算し UART 出力 |
| `zig build demo_b` | ゲストが 9 から 0 へカウントダウン (条件分岐) |
| `zig build demo_c` | UART RX 双方向 (host stdin → guest → echo) |
| `zig build demo_d` | vTimer で 5 回ハートビート (~0.5秒 周期) |

## 🧪 テスト

```bash
zig build test
# 103/103 passed: vmcore 53 + dtb 23 + gic 14 + pl011 13
```

純粋ロジック (Hypervisor.framework に依存しない部分) を全テスト。

## 🔗 関連プロジェクト

- `../202601zigos` — ZigVM 上で動く自作 mini-OS。GIC + IRQ + DTB + 例外ベクタの自前実装
- `../linuximg` — Linux Image format 互換の最小カーネル (動作検証用)

## 📄 ライセンス

Mozilla Public License 2.0 ([LICENSE](LICENSE) 参照)
