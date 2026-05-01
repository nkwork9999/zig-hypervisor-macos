// Apple Hypervisor.framework bindings + ARM64 / GIC / PSCI constants.
// 全てのデモ・main.zigでimportして共有する。
//
// 注: このファイルは extern "Hypervisor" を含むので、テスト用ビルドからは
// import しないこと。テストには src/vmcore.zig や個別モジュールを使う。

pub const hv_return_t = i32;
pub const HV_SUCCESS: hv_return_t = 0;
pub const HV_MEMORY_READ: u64 = 1 << 0;
pub const HV_MEMORY_WRITE: u64 = 1 << 1;
pub const HV_MEMORY_EXEC: u64 = 1 << 2;

// hv_reg_t enum (cf. /Library/.../Hypervisor.framework/Headers/hv_vcpu_types.h)
// 順序: X0..X29(0-29), X30(30=LR), PC(31), FPCR(32), FPSR(33), CPSR(34)
pub const HV_REG_X0: u32 = 0;
pub const HV_REG_X1: u32 = 1;
pub const HV_REG_PC: u32 = 31;
pub const HV_REG_CPSR: u32 = 34;

// hv_sys_reg_t (CRn,CRm,op0,op1,op2 から計算: (op0<<14)|(op1<<11)|(CRn<<7)|(CRm<<3)|op2)
pub const HV_SYS_REG_VBAR_EL1: u16 = 0xC600;
pub const HV_SYS_REG_SP_EL0: u16 = 0xC208;
pub const HV_SYS_REG_SP_EL1: u16 = 0xE208;
pub const HV_SYS_REG_CNTV_CTL_EL0: u16 = 0xDF19;
pub const HV_SYS_REG_CNTV_CVAL_EL0: u16 = 0xDF1A;

// 例外クラス (ESR_EL2.EC)
pub const EC_HVC: u32 = 0x16;
pub const EC_DATA_ABORT: u32 = 0x24;
pub const EC_BRK: u32 = 0x3C;

// hv_exit_reason_t
pub const HV_EXIT_REASON_CANCELED: u32 = 0;
pub const HV_EXIT_REASON_EXCEPTION: u32 = 1;
pub const HV_EXIT_REASON_VTIMER_ACTIVATED: u32 = 2;

// hv_interrupt_type_t
pub const HV_INTERRUPT_TYPE_IRQ: u32 = 0;
pub const HV_INTERRUPT_TYPE_FIQ: u32 = 1;

// CPSR for EL1h (SPsel=1) with all DAIF masked
pub const CPSR_EL1H_DAIF_MASKED: u64 = 0x3c5;

pub const HVExitInfo = extern struct {
    reason: u32,
    exception: extern struct {
        syndrome: u64,
        virtual_address: u64,
        physical_address: u64,
    },
};

// ----- Hypervisor.framework C API -----

pub extern "Hypervisor" fn hv_vm_create(config: ?*anyopaque) hv_return_t;
pub extern "Hypervisor" fn hv_vm_destroy() hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_create(vcpu: *u64, exit: **HVExitInfo, config: ?*anyopaque) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_destroy(vcpu: u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_run(vcpu: u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_get_reg(vcpu: u64, reg: u32, value: *u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_set_reg(vcpu: u64, reg: u32, value: u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_set_sys_reg(vcpu: u64, reg: u16, value: u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_set_trap_debug_exceptions(vcpu: u64, enable: bool) hv_return_t;
pub extern "Hypervisor" fn hv_vm_map(addr: *anyopaque, ipa: u64, size: usize, flags: u64) hv_return_t;
pub extern "Hypervisor" fn hv_vm_unmap(ipa: u64, size: usize) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_set_vtimer_mask(vcpu: u64, masked: bool) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_get_vtimer_offset(vcpu: u64, offset: *u64) hv_return_t;
pub extern "Hypervisor" fn hv_vcpu_set_pending_interrupt(vcpu: u64, typ: u32, pending: bool) hv_return_t;

pub extern "c" fn mach_absolute_time() u64;
