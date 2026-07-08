
#include <stdio.h>              // printf/fprintf/perror/fopen/fread/fclose 等 C 标准 IO
#include <stdint.h>             // uint32_t/uint64_t 等固定宽度整数类型
#include <stdlib.h>             // getenv/atoi 等通用工具函数
#include <string.h>             // memset/memcpy/strcmp/strtok/strncpy 等字符串和内存操作
#include <assert.h>             // assert(), 用于仿真期遇到严重错误时直接停下
#include <nvboard.h>            // NVBoard GUI 接口; 非 GUI 编译时由宏控制是否真正使用
#include <VysyxSoCFull.h>       // Verilator 生成的 ysyxSoCFull 顶层 C++ 模型
#include "verilated.h"          // Verilator 运行时接口, 如 commandArgs/gotFinish
#include <sys/time.h>           // gettimeofday(), 用于统计宿主机仿真耗时
#include <capstone/capstone.h>  // Capstone 反汇编库, 用于 itrace 打印指令
#include <libelf.h>             // libelf, 用于读取 ELF 符号表
#include <gelf.h>               // libelf 的通用 ELF 类型接口
#include <fcntl.h>              // fcntl/O_NONBLOCK, 用于把 stdin 设置成非阻塞
#include <unistd.h>             // read/close, 用于读取终端输入和关闭文件描述符
#include <errno.h>              // errno/EAGAIN/EWOULDBLOCK, 处理非阻塞 read 的结果
#include <vector>               // std::vector, 保存 ftrace 符号表
#include <dlfcn.h>              // dlopen/dlsym, 动态加载 NEMU difftest so

static FILE *pc_trace_fp = NULL; // 若开启 PC trace, 这里保存输出文件句柄

// 这些函数在 Verilog 中通过 DPI-C export 出来, C++ 侧可以直接读取 CPU 内部状态.
extern "C" int npc_read_gpr(int idx);     // 读取 NPC 的通用寄存器 x0~x15
extern "C" uint32_t npc_read_pc();        // 读取 NPC 当前 PC
extern "C" int npc_is_commit();           // 查询本周期是否有指令提交
extern "C" int npc_check_skip();          // 查询当前指令是否需要跳过 difftest

bool is_skip_ref = false;                 // C++ 侧标记: 本次访存/设备访问需要同步 REF 而不是逐步比较

static VysyxSoCFull dut;                  // Verilator 生成的 SoC 顶层实例, 后续所有仿真都驱动它

#ifdef ENABLE_NVBOARD
void nvboard_bind_all_pins(VysyxSoCFull* top); // NVBoard 自动生成/手写的引脚绑定函数
#endif

static const int UART_BIT_TICKS = 16;     // 仿真 UART 每个 bit 持续多少个 NPC 周期
static bool uart_stdin_enabled = false;   // reset 期间禁止从 stdin 向 UART RX 注入字符
static bool uart_stdin_inited = false;    // stdin 是否已经被设置为非阻塞
static uint16_t uart_rx_frame = 0x3ff;    // 正在发送到 RX 引脚的 8N1 串口帧: start + 8 data + stop
static int uart_rx_bits = 0;              // 当前帧还剩多少 bit 没有发完
static int uart_rx_ticks = 0;             // 当前 bit 还需要维持多少周期
static bool uart_debug_enabled = false;   // 是否打印 stdin->UART RX 的调试日志
static bool uart_stdin_requested = false; // 是否把 host stdin 注入到 guest UART RX

static void init_uart_stdin() {
  if (uart_stdin_inited) return;
  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags >= 0) {
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
  }
  uart_stdin_inited = true;
}

static int read_uart_stdin_byte() {
  init_uart_stdin();
  unsigned char ch;
  ssize_t n = read(STDIN_FILENO, &ch, 1);
  if (n == 1) return ch;
  if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
    return -1;
  }
  return -1;
}

static void drive_uart_rx() {
#ifdef ENABLE_NVBOARD
  (void)read_uart_stdin_byte;
#else
  if (!uart_stdin_enabled) {
    dut.externalPins_uart_rx = 1;
    return;
  }

  if (uart_rx_bits == 0) {
    int ch = read_uart_stdin_byte();
    if (ch < 0) {
      dut.externalPins_uart_rx = 1;
      return;
    }
    if (uart_debug_enabled) {
      fprintf(stderr, "[UART-RX stdin] 0x%02x '%c'\n", ch & 0xff,
              (ch >= 32 && ch < 127) ? ch : '.');
    }
    uart_rx_frame = (1u << 9) | ((uint16_t)(ch & 0xff) << 1);
    uart_rx_bits = 10;
    uart_rx_ticks = UART_BIT_TICKS;
  }

  dut.externalPins_uart_rx = uart_rx_frame & 1u;
  if (--uart_rx_ticks == 0) {
    uart_rx_frame = (uart_rx_frame >> 1) | 0x200u;
    uart_rx_bits--;
    uart_rx_ticks = UART_BIT_TICKS;
  }
#endif
}

// =======================================================================
// MROM 定义 (0x2000_0000 ~ 0x2000_0fff)
// =======================================================================
#define MROM_SIZE 0x1000 
uint8_t mrom[MROM_SIZE];                                  // 仿真侧 MROM 内容, 通过 DPI 给 RTL 读取
#define MROM_BASE 0x20000000                              // ysyxSoC 中 MROM 的物理基地址
#define SRAM_BASE 0x0f000000                              // 仿真侧简单 SRAM 的物理基地址
#define SRAM_SIZE 0x2000                                  // 当前只建模 8KB SRAM
#define FLASH_BASE 0x30000000                             // Flash 物理基地址
#define FLASH_SIZE 0x1000000                              // 当前仿真侧 Flash 容量 16MB
uint8_t sram[SRAM_SIZE];                                  // 仿真侧 SRAM 数组
uint8_t flash[FLASH_SIZE];                                // 仿真侧 Flash 数组
static long img_size_loaded = 0;                          // 记录镜像大小, 初始化 difftest 时会用到
static bool flash_boot = false;                           // 是否从 Flash 启动; 由 --flash-boot 设置
static const char *ref_so_file = getenv("NEMU_REF_SO") ? getenv("NEMU_REF_SO") : "../nemu/build/riscv32-nemu-interpreter-so"; // 默认 NEMU REF so 路径

#define ENABLE_ITRACE 0                                   // 是否打印指令执行轨迹
#define ENABLE_MTRACE 0                                   // 是否打印访存轨迹; 当前文件中暂未展开使用
#define ENABLE_FTRACE 0                                   // 是否打印函数调用/返回轨迹
#define ENABLE_DIFFTEST 1                                 // 是否编译 difftest 逻辑

typedef uint32_t paddr_t;                                 // 物理地址类型
typedef uint32_t word_t;                                  // 机器字类型

enum {DIFFTEST_TO_DUT, DIFFTEST_TO_REF};                  // difftest 数据拷贝方向

typedef struct {
    char name[128];                                       // 函数名
    uint32_t addr;                                        // 函数起始地址
    uint32_t size;                                        // 函数大小
} Symbol;

struct diff_context_t {
    uint32_t gpr[16];                                     // riscv32e 只使用 x0~x15
    uint32_t pc;                                          // REF/DUT 当前 PC
    uint32_t csr[4];                                      // 预留 CSR 同步空间
};

void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL; // REF 内存拷贝接口
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;                         // REF 寄存器拷贝接口
void (*ref_difftest_exec)(uint64_t n) = NULL;                                          // REF 执行 n 条指令
void (*ref_difftest_raise_intr)(word_t NO) = NULL;                                     // REF 触发中断接口; 当前未使用
void (*ref_difftest_init)(int port) = NULL;                                            // REF 初始化接口

std::vector<Symbol> symbol_table;                         // ELF 函数符号表, 给 ftrace 使用
int  call_depth = 0;                                      // ftrace 缩进深度, 表示当前函数调用层级

extern "C" int npc_reset_pc() {
    return flash_boot ? FLASH_BASE : MROM_BASE;           // RTL 复位时通过 DPI 询问起始 PC
}

// =======================================================================
// 自动获取正确的 DPI-C 作用域 (智能匹配常见路径)
// =======================================================================
svScope get_dpi_scope() {
    static svScope scope = NULL;
    if (scope == NULL) {
        const char* possible_scopes[] = {
            "ysyxSoCFull.asic.cpu.cpu.cpu",
            "ysyxSoCFull.asic.cpu.cpu.ysyx_26060181",
            "ysyxSoCFull.asic.cpu.cpu",
            "ysyxSoCFull.asic.cpu",
            "ysyxSoCFull.asic.cpu.ysyx_00000000",
            "ysyxSoCFull.asic.cpu.ysyx_26060181",
            "TOP.ysyxSoCFull.asic.cpu.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu.cpu.ysyx_26060181",
            "TOP.ysyxSoCFull.asic.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_26060181",
            "TOP.ysyxSoCFull.cpu.cpu",
            "TOP.ysyxSoCFull.cpu",
            "TOP.ysyxSoCFull.asic.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.ysyx_26060181",
            "TOP.ysyxSoCFull.ysyx_00000000",
            "TOP.ysyxSoCFull.ysyx_26060181"
        };
        for (size_t i = 0; i < sizeof(possible_scopes) / sizeof(possible_scopes[0]); i++) {
            scope = svGetScopeFromName(possible_scopes[i]);
            if (scope) {
                printf("\033[1;32m[NPC] 成功匹配到 DPI-C 作用域: %s\033[0m\n", possible_scopes[i]);
                break;
            }
        }
        if (!scope) {
            printf("\n\033[1;31m[ERROR] 所有的预设作用域都未找到！\033[0m\n");
            printf("请在终端运行: grep -r \"svGetScopeFromName\" build/obj_dir/ 来查看真实的路径。\n");
            assert(0);                                      // 没找到 scope 时后续 DPI 读内部信号会失败, 直接终止
        }
    }
    return scope;                                           // 返回可用于 svSetScope() 的作用域
}

void init_elf(const char *elf_file) {
    if(elf_file == NULL){
        printf("FTRACE: No ELF file provided, function names will be shown as ???\n");
        return;                                             // 没传 ELF 时不启用 ftrace 符号解析
    }
    int fd = open(elf_file, O_RDONLY);                      // 打开 ELF 文件
    if(fd < 0){perror("open elf"); return;}                 // 打不开就放弃 ftrace, 不影响仿真主体
    elf_version(EV_CURRENT);                                // 初始化 libelf 版本
    Elf *e = elf_begin(fd, ELF_C_READ, NULL);               // 创建 ELF 读句柄
    Elf_Scn *scn = NULL;                                    // section 遍历游标
    GElf_Shdr shdr;                                         // section header
    while((scn = elf_nextscn(e, scn)) != NULL) {
        gelf_getshdr(scn, &shdr);                           // 读取当前 section 的 header
        if(shdr.sh_type == SHT_SYMTAB) {
            Elf_Data *data = elf_getdata(scn, NULL);        // 取符号表数据
            int count = shdr.sh_size / shdr.sh_entsize;     // 符号数量
            for(int i = 0; i < count; i++) {
                GElf_Sym sym;                               // 单个 ELF 符号
                gelf_getsym(data, i, &sym);                 // 读取第 i 个符号
                if(GELF_ST_TYPE(sym.st_info) == STT_FUNC && sym.st_size > 0) {
                    Symbol s;                               // 只保存函数符号, 用于 call/ret 显示函数名
                    strncpy(s.name, elf_strptr(e, shdr.sh_link, sym.st_name),127); // 从字符串表取函数名
                    s.addr = sym.st_value;                  // 函数起始地址
                    s.size = sym.st_size;                   // 函数范围大小
                    symbol_table.push_back(s);              // 加入本地符号表
                }
            }
        }
    }
    elf_end(e);                                             // 释放 ELF 句柄
    close(fd);                                              // 关闭文件
    printf("FTRACE: Loaded %ld symbols from %s\n", symbol_table.size(), elf_file);
}

const char* find_symbol(uint32_t addr){
    for(auto &s : symbol_table){
        if(addr >= s.addr && addr < s.addr + s.size){
            return s.name;                                  // 地址落在某个函数范围内, 返回函数名
        }
    }
    return NULL;                                            // 找不到符号就返回 NULL, 打印时显示 ???
}

void ftrace_print(uint32_t pc, uint32_t target, bool is_call){
    if(!ENABLE_FTRACE) return;                              // 编译期开关关闭时直接返回
    const char* func_name = find_symbol(target);            // 根据跳转目标地址查函数名
    printf("\033[1;34m[FTRACE]\033[0m");                    // 打印 ftrace 前缀
    for(int i = 0; i < call_depth; i++) printf("  ");       // 根据调用深度缩进
    if(is_call){
        printf("0x%08x: call [%s@0x%08x]\n", pc, func_name ? func_name : "???", target);
        call_depth++;                                       // call 后进入更深一层
    }else{
        call_depth--;                                       // ret 后回到上一层
        if(call_depth < 0) call_depth = 0;                  // 防止异常情况下缩进变负
        printf("0x%08x: ret  [%s]\n", pc, func_name ? func_name : "???");
    }
}

static csh capstone_handle;                                 // Capstone 反汇编器句柄
static bool capstone_initialized = false;                   // 标记 Capstone 是否初始化成功

void init_disasm() {
    cs_err err = cs_open(CS_ARCH_RISCV, CS_MODE_RISCV32, &capstone_handle); // 创建 RISC-V 32 位反汇编器
    if (err != CS_ERR_OK) {
        printf("WARNING: Capstone RISC-V init failed: %s, itrace will print raw instructions only.\n",
               cs_strerror(err));
        return;                                             // 初始化失败时仍打印 raw itrace, 不阻塞仿真
    }
    capstone_initialized = true;                            // 后续 itrace 可以调用 cs_disasm
    printf("Capstone initialized successfully.\n");
}

extern "C" void npc_itrace_commit(uint32_t pc, uint32_t inst, uint32_t dnpc) {
    if (pc_trace_fp != NULL) {
        fprintf(pc_trace_fp, "0x%08x\n", pc);              // cachesim 使用的简化 PC 序列
    }
    #if ENABLE_ITRACE
    if (capstone_initialized) {
        cs_insn* insn;                                      // Capstone 输出的指令结构体数组
        size_t count = cs_disasm(capstone_handle, (const uint8_t*)&inst, 4, pc, 0, &insn); // 反汇编当前 4B 指令
        if (count > 0) {
            printf("[ITRACE] 0x%08x: %08x    %-7s %s\n", pc, inst, insn[0].mnemonic, insn[0].op_str);
            cs_free(insn, count);                           // 释放 Capstone 分配的结果
        } else {
            printf("[ITRACE] 0x%08x: %08x    (Unknown Instruction)\n", pc, inst);
        }
    } else {
        printf("[ITRACE] 0x%08x: %08x    -> 0x%08x\n", pc, inst, dnpc);
    }
    #endif

    #if ENABLE_FTRACE
    uint32_t opcode = inst & 0x7F;                          // 取 opcode 判断 jal/jalr
    uint32_t rd     = (inst >> 7) & 0x1F;                   // 取 rd 判断是否写 ra
    uint32_t rs1    = (inst >> 15) & 0x1F;                  // 取 rs1 判断是否从 ra 返回

    bool is_jal  = (opcode == 0x6F);                        // JAL 指令
    bool is_jalr = (opcode == 0x67);                        // JALR 指令

    if ((is_jal || is_jalr) && (rd == 1)) {
        ftrace_print(pc, dnpc, true);                       // 写 ra 的跳转视为函数调用
    }
    else if (is_jalr && (rs1 == 1) && (rd == 0)) {
        ftrace_print(pc, pc, false);                        // ret 从当前 PC 所在函数返回
    }
    #endif
}

void init_difftest(const char *ref_so_file, long img_size) {
#if ENABLE_DIFFTEST
    if(ref_so_file == NULL){
        printf("WARNING: No reference shared object provided for difftest! Running in pure simulation mode.\n");
        return;                                             // --no-difftest 时跳过 REF 初始化
    }
    void *handle = dlopen(ref_so_file, RTLD_LAZY);          // 动态加载 NEMU REF so
    assert(handle);                                         // so 加载失败说明路径或编译结果有问题
    ref_difftest_memcpy = (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy"); // 查找内存同步函数
    ref_difftest_regcpy = (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");                  // 查找寄存器同步函数
    ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");                          // 查找 REF 执行函数
    ref_difftest_init = (void (*)(int))dlsym(handle, "difftest_init");                               // 查找 REF 初始化函数
    assert(ref_difftest_memcpy && ref_difftest_regcpy && ref_difftest_exec && ref_difftest_init);    // 必要接口必须存在
    
    svSetScope(get_dpi_scope());                            // 之后要通过 DPI 读寄存器/PC, 先设置正确作用域
    
    ref_difftest_init(0);                                    // 初始化 REF
    memset(sram, 0, sizeof(sram));                           // SRAM 初始清零, 与 RTL 侧简单模型保持一致
    ref_difftest_memcpy(MROM_BASE, mrom, MROM_SIZE, DIFFTEST_TO_REF); // 把 MROM 内容同步到 REF
    ref_difftest_memcpy(SRAM_BASE, sram, sizeof(sram), DIFFTEST_TO_REF); // 把 SRAM 内容同步到 REF
    if (flash_boot) {
        ref_difftest_memcpy(FLASH_BASE, flash, img_size, DIFFTEST_TO_REF); // Flash 启动时也同步 Flash 镜像
    }

    diff_context_t ctx ;                                     // 用于初始化 REF 寄存器状态
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT);              // 先从 REF 读一个上下文模板
    ctx.pc = npc_read_pc();                                  // REF PC 对齐到 DUT 当前 PC
    for(int i = 0; i < 16; i++) {
        ctx.gpr[i] = npc_read_gpr(i);                        // REF GPR 对齐到 DUT GPR
    }
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_REF);              // 写回 REF, 完成初始状态同步
   
    printf("DiffTest initialized with %s\n", ref_so_file);
#endif
}

void checkregs(diff_context_t * ref) {
    bool mismatch = false;                                   // 记录是否发现寄存器不一致
    uint32_t dut_pc = npc_read_pc();
    if (dut_pc != ref->pc) {
        mismatch = true;
        printf("PC mismatch: NPC=0x%08x, REF=0x%08x\n", dut_pc, ref->pc);
    }
    for(int i = 0; i < 16; i++){
            if(npc_read_gpr(i) != ref->gpr[i]) {
                mismatch = true;                             // 任意寄存器不一致就标记失败
                printf("Register x%d mismatch: NPC=0x%08x, REF=0x%08x\n", i, npc_read_gpr(i), ref->gpr[i]);
            }
        }
    if(mismatch) {
      printf("DiffTest failed at PC = 0x%08x\n", ref->pc);
      fflush(stdout);
      assert(0);                                             // difftest 不一致, 直接停止仿真
    }
}

static uint64_t boot_time = 0;                              // 仿真开始时的宿主机时间, 用来算 wall time
static uint64_t perf_cycles = 0;                            // NPC 仿真周期数
static uint64_t perf_insts = 0;                             // NPC 动态提交指令数

enum {
  PERF_CAT_ALU = 0,                                         // 普通计算类指令
  PERF_CAT_LOAD,                                            // load 指令
  PERF_CAT_STORE,                                           // store 指令
  PERF_CAT_BRANCH,                                          // 条件分支指令
  PERF_CAT_JUMP,                                            // jal/jalr 等跳转指令
  PERF_CAT_CSR,                                             // CSR 指令
  PERF_CAT_SYSTEM,                                          // ecall/mret 等系统类指令
  PERF_CAT_OTHER,                                           // 其他未分类指令
  PERF_CAT_NR                                               // 类别数量
};

enum {
  PERF_EVT_IFU_FETCH = 0,                                   // IFU 成功取到一条指令
  PERF_EVT_LSU_LOAD_DATA = 1,                               // LSU 成功拿到 load 数据
  PERF_EVT_LSU_STORE_DONE = 2,                              // LSU 成功完成 store 写响应
  PERF_EVT_EXU_DONE = 3,                                    // EXU 完成一次非访存计算/控制流执行
  PERF_EVT_ICACHE_HIT = 4,                                  // I-cache 命中一次
  PERF_EVT_ICACHE_MISS = 5,                                 // I-cache 缺失一次
  PERF_EVT_IFU_WAIT_REQ = 10,                               // IFU 因取指请求无法发出而等待
  PERF_EVT_IFU_WAIT_RSP = 11,                               // IFU 因等待取指响应而等待
  PERF_EVT_IFU_WAIT_LSU_LD = 12,                            // IFU 因 LSU load 占用执行流而无法取指
  PERF_EVT_IFU_WAIT_LSU_ST = 13,                            // IFU 因 LSU store 占用执行流而无法取指
  PERF_EVT_LSU_LOAD_LAT = 20,                               // 一次 load latency 样本
  PERF_EVT_LSU_STORE_LAT = 21,                              // 一次 store latency 样本
  PERF_EVT_ICACHE_MISS_LAT = 22                             // 一次 I-cache miss penalty 样本
};

static const char *perf_cat_name[PERF_CAT_NR] = {
  "ALU", "LOAD", "STORE", "BRANCH", "JUMP", "CSR", "SYSTEM", "OTHER"
};

static uint64_t perf_cat_count[PERF_CAT_NR];                // 每类指令的提交数量
static uint64_t perf_cat_cycles[PERF_CAT_NR];               // 每类指令累计消耗周期
static uint64_t perf_ifu_fetch = 0;                         // IFU 取到指令次数
static uint64_t perf_lsu_load_data = 0;                     // LSU load 完成次数
static uint64_t perf_lsu_store_done = 0;                    // LSU store 完成次数
static uint64_t perf_exu_done = 0;                          // EXU 完成次数
static uint64_t perf_icache_hit = 0;                        // I-cache 命中次数
static uint64_t perf_icache_miss = 0;                       // I-cache 缺失次数
static uint64_t perf_ifu_wait_req = 0;                      // IFU 请求阶段等待周期数
static uint64_t perf_ifu_wait_rsp = 0;                      // IFU 响应阶段等待周期数
static uint64_t perf_ifu_wait_lsu_ld = 0;                   // LSU load 导致 IFU 不取指周期数
static uint64_t perf_ifu_wait_lsu_st = 0;                   // LSU store 导致 IFU 不取指周期数
static uint64_t perf_lsu_load_lat_sum = 0;                  // load latency 总和
static uint64_t perf_lsu_store_lat_sum = 0;                 // store latency 总和
static uint64_t perf_lsu_load_lat_count = 0;                // load latency 样本数
static uint64_t perf_lsu_store_lat_count = 0;               // store latency 样本数
static uint64_t perf_icache_miss_lat_sum = 0;               // I-cache miss penalty 总和, 即 TMT
static uint64_t perf_icache_miss_lat_count = 0;             // I-cache miss penalty 样本数

static uint64_t get_time_internal(){
    struct timeval now;                                     // timeval 保存秒和微秒
    gettimeofday(&now, NULL);                               // 获取宿主机当前时间
    return now.tv_sec * 1000000ull + now.tv_usec;           // 统一转换成微秒
}

static void reset_perf_stats() {
  perf_cycles = 0;                                          // 清空周期计数
  perf_insts = 0;                                           // 清空指令计数
  memset(perf_cat_count, 0, sizeof(perf_cat_count));        // 清空指令类别数量
  memset(perf_cat_cycles, 0, sizeof(perf_cat_cycles));      // 清空指令类别周期
  perf_ifu_fetch = 0;                                       // 以下逐项清空性能事件计数器
  perf_lsu_load_data = 0;
  perf_lsu_store_done = 0;
  perf_exu_done = 0;
  perf_icache_hit = 0;
  perf_icache_miss = 0;
  perf_ifu_wait_req = 0;
  perf_ifu_wait_rsp = 0;
  perf_ifu_wait_lsu_ld = 0;
  perf_ifu_wait_lsu_st = 0;
  perf_lsu_load_lat_sum = 0;
  perf_lsu_store_lat_sum = 0;
  perf_lsu_load_lat_count = 0;
  perf_lsu_store_lat_count = 0;
  perf_icache_miss_lat_sum = 0;
  perf_icache_miss_lat_count = 0;
  boot_time = get_time_internal();                          // 重新记录性能统计起点时间
}

extern "C" void npc_perf_event(int event, int data) {
  switch (event) {
    case PERF_EVT_IFU_FETCH:       perf_ifu_fetch++; break;       // RTL 上报一次取指完成
    case PERF_EVT_LSU_LOAD_DATA:   perf_lsu_load_data++; break;   // RTL 上报一次 load 完成
    case PERF_EVT_LSU_STORE_DONE:  perf_lsu_store_done++; break;  // RTL 上报一次 store 完成
    case PERF_EVT_EXU_DONE:        perf_exu_done++; break;        // RTL 上报一次 EXU 完成
    case PERF_EVT_ICACHE_HIT:      perf_icache_hit++; break;      // RTL 上报一次 I-cache hit
    case PERF_EVT_ICACHE_MISS:     perf_icache_miss++; break;     // RTL 上报一次 I-cache miss
    case PERF_EVT_IFU_WAIT_REQ:    perf_ifu_wait_req++; break;    // RTL 上报一个 IFU req wait 周期
    case PERF_EVT_IFU_WAIT_RSP:    perf_ifu_wait_rsp++; break;    // RTL 上报一个 IFU rsp wait 周期
    case PERF_EVT_IFU_WAIT_LSU_LD: perf_ifu_wait_lsu_ld++; break; // RTL 上报一个 LSU load busy 周期
    case PERF_EVT_IFU_WAIT_LSU_ST: perf_ifu_wait_lsu_st++; break; // RTL 上报一个 LSU store busy 周期
    case PERF_EVT_LSU_LOAD_LAT:
      perf_lsu_load_lat_sum += (uint32_t)data;             // data 携带本次 load 的周期数
      perf_lsu_load_lat_count++;                           // 增加 load latency 样本数
      break;
    case PERF_EVT_LSU_STORE_LAT:
      perf_lsu_store_lat_sum += (uint32_t)data;            // data 携带本次 store 的周期数
      perf_lsu_store_lat_count++;                          // 增加 store latency 样本数
      break;
    case PERF_EVT_ICACHE_MISS_LAT:
      perf_icache_miss_lat_sum += (uint32_t)data;          // data 携带本次 I-cache miss penalty
      perf_icache_miss_lat_count++;                        // 增加 miss penalty 样本数
      break;
    default:
      break;                                                // 未识别事件忽略, 防止 RTL/C++ 编号临时不一致时崩溃
  }
}

extern "C" void npc_perf_commit(int category, int cycles) {
  if (category < 0 || category >= PERF_CAT_NR) {
    category = PERF_CAT_OTHER;                              // 越界类别归到 OTHER
  }
  perf_cat_count[category]++;                               // 当前类别提交数量加一
  perf_cat_cycles[category] += (uint32_t)cycles;            // 累加当前指令执行周期
}

static void print_perf_stats() {
  uint64_t elapsed_us = get_time_internal() - boot_time;    // 宿主机实际运行时间
  double ipc = perf_cycles == 0 ? 0.0 : (double)perf_insts / (double)perf_cycles; // IPC = inst/cycle
  double cpi = perf_insts == 0 ? 0.0 : (double)perf_cycles / (double)perf_insts;  // CPI = cycle/inst
  double sim_freq = elapsed_us == 0 ? 0.0 : (double)perf_cycles / (double)elapsed_us; // 仿真速度 cycles/us
  uint64_t decoded_insts = 0;                               // 所有译码类别计数之和
  uint64_t ifu_wait_total = perf_ifu_wait_req + perf_ifu_wait_rsp + perf_ifu_wait_lsu_ld + perf_ifu_wait_lsu_st; // IFU 不取指总周期
  uint64_t icache_access = perf_icache_hit + perf_icache_miss; // I-cache 总访问次数
  double icache_miss_rate = icache_access == 0 ? 0.0 : (double)perf_icache_miss / (double)icache_access; // miss rate
  double icache_access_time = 1.0;                          // 当前模型把 cache 命中访问时间近似为 1 cycle
  double icache_avg_miss_penalty =
    perf_icache_miss_lat_count == 0 ? 0.0 : (double)perf_icache_miss_lat_sum / (double)perf_icache_miss_lat_count; // 平均 miss penalty
  double icache_amat = icache_access_time + icache_miss_rate * icache_avg_miss_penalty; // AMAT = hit time + miss rate * miss penalty

  printf("========== NPC Performance ==========\n");
  printf("cycles        : %llu\n", (unsigned long long)perf_cycles);
  printf("instructions  : %llu\n", (unsigned long long)perf_insts);
  printf("IPC           : %.6f\n", ipc);
  printf("CPI           : %.6f\n", cpi);
  printf("host time     : %.3f ms\n", (double)elapsed_us / 1000.0);
  printf("sim speed     : %.3f cycles/us\n", sim_freq);
  printf("---------- performance events --------\n");
  printf("IFU fetch inst: %llu\n", (unsigned long long)perf_ifu_fetch);
  printf("LSU load data : %llu\n", (unsigned long long)perf_lsu_load_data);
  printf("LSU store done: %llu\n", (unsigned long long)perf_lsu_store_done);
  printf("EXU done      : %llu\n", (unsigned long long)perf_exu_done);
  printf("I$ hit        : %llu\n", (unsigned long long)perf_icache_hit);
  printf("I$ miss       : %llu\n", (unsigned long long)perf_icache_miss);
  printf("I$ hit rate   : %.2f%%\n",
         icache_access == 0 ? 0.0 : 100.0 * (double)perf_icache_hit / (double)icache_access);
  printf("---------- I-cache AMAT --------------\n");
  printf("I$ access time: %.3f cycles\n", icache_access_time);
  printf("I$ miss avg   : %.3f cycles (%llu samples)\n",
         icache_avg_miss_penalty,
         (unsigned long long)perf_icache_miss_lat_count);
  printf("I$ TMT        : %llu cycles\n", (unsigned long long)perf_icache_miss_lat_sum);
  printf("I$ AMAT       : %.3f cycles/access\n", icache_amat);
  printf("---------- instruction mix -----------\n");
  for (int i = 0; i < PERF_CAT_NR; i++) {
    decoded_insts += perf_cat_count[i];
    double ratio = perf_insts == 0 ? 0.0 : 100.0 * (double)perf_cat_count[i] / (double)perf_insts;
    double avg_cycles = perf_cat_count[i] == 0 ? 0.0 : (double)perf_cat_cycles[i] / (double)perf_cat_count[i];
    printf("%-7s: %10llu  %6.2f%%  avg cycles %.3f\n",
           perf_cat_name[i], (unsigned long long)perf_cat_count[i], ratio, avg_cycles);
  }
  printf("---------- IFU not-fetch reasons -----\n");
  printf("req wait      : %10llu  %6.2f%% of no-fetch, %6.2f%% of cycles\n",
         (unsigned long long)perf_ifu_wait_req,
         ifu_wait_total == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_req / (double)ifu_wait_total,
         perf_cycles == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_req / (double)perf_cycles);
  printf("rsp wait      : %10llu  %6.2f%% of no-fetch, %6.2f%% of cycles\n",
         (unsigned long long)perf_ifu_wait_rsp,
         ifu_wait_total == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_rsp / (double)ifu_wait_total,
         perf_cycles == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_rsp / (double)perf_cycles);
  printf("LSU load busy : %10llu  %6.2f%% of no-fetch, %6.2f%% of cycles\n",
         (unsigned long long)perf_ifu_wait_lsu_ld,
         ifu_wait_total == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_lsu_ld / (double)ifu_wait_total,
         perf_cycles == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_lsu_ld / (double)perf_cycles);
  printf("LSU store busy: %10llu  %6.2f%% of no-fetch, %6.2f%% of cycles\n",
         (unsigned long long)perf_ifu_wait_lsu_st,
         ifu_wait_total == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_lsu_st / (double)ifu_wait_total,
         perf_cycles == 0 ? 0.0 : 100.0 * (double)perf_ifu_wait_lsu_st / (double)perf_cycles);
  printf("---------- LSU latency ---------------\n");
  printf("load avg      : %.3f cycles (%llu samples)\n",
         perf_lsu_load_lat_count == 0 ? 0.0 : (double)perf_lsu_load_lat_sum / (double)perf_lsu_load_lat_count,
         (unsigned long long)perf_lsu_load_lat_count);
  printf("store avg     : %.3f cycles (%llu samples)\n",
         perf_lsu_store_lat_count == 0 ? 0.0 : (double)perf_lsu_store_lat_sum / (double)perf_lsu_store_lat_count,
         (unsigned long long)perf_lsu_store_lat_count);
  printf("---------- consistency checks --------\n");
  printf("decoded == inst      : %s (%llu vs %llu)\n",
         decoded_insts == perf_insts ? "PASS" : "FAIL",
         (unsigned long long)decoded_insts, (unsigned long long)perf_insts);
  printf("IFU fetch == inst    : %s (%llu vs %llu)\n",
         perf_ifu_fetch == perf_insts ? "PASS" : "FAIL",
         (unsigned long long)perf_ifu_fetch, (unsigned long long)perf_insts);
  printf("I$ access == IFU     : %s (%llu vs %llu)\n",
         icache_access == perf_ifu_fetch ? "PASS" : "FAIL",
         (unsigned long long)icache_access, (unsigned long long)perf_ifu_fetch);
  printf("I$ miss lat samples  : %s (%llu vs %llu)\n",
         perf_icache_miss_lat_count == perf_icache_miss ? "PASS" : "FAIL",
         (unsigned long long)perf_icache_miss_lat_count, (unsigned long long)perf_icache_miss);
  printf("LOAD count == LSU LD : %s (%llu vs %llu)\n",
         perf_cat_count[PERF_CAT_LOAD] == perf_lsu_load_data ? "PASS" : "FAIL",
         (unsigned long long)perf_cat_count[PERF_CAT_LOAD], (unsigned long long)perf_lsu_load_data);
  printf("STORE count == LSU ST: %s (%llu vs %llu)\n",
         perf_cat_count[PERF_CAT_STORE] == perf_lsu_store_done ? "PASS" : "FAIL",
         (unsigned long long)perf_cat_count[PERF_CAT_STORE], (unsigned long long)perf_lsu_store_done);
  printf("=====================================\n");
}

void single_cycle() {
  drive_uart_rx();                                          // 每个周期前先更新 UART RX 输入引脚
  dut.clock = 0;dut.eval();                                 // 时钟拉低并求值一次组合逻辑
  dut.clock = 1;dut.eval();                                 // 时钟拉高, 触发 RTL 时序逻辑
  perf_cycles++;                                            // 完成一个完整周期后累计周期数
#ifdef ENABLE_NVBOARD
  nvboard_update();                                         // GUI 模式下刷新 NVBoard 界面和输入事件
#endif
}

void reset(int n) {
  dut.reset = 1;                                            // 拉高 SoC reset
  uart_stdin_enabled = false;                               // reset 期间不要向 UART 注入输入
  while(n-- >0) single_cycle();                             // 保持 reset 若干周期; ChipLink/SoC 初始化也需要足够 reset 时间
  dut.reset = 0;                                            // 释放 reset, CPU 开始从 npc_reset_pc() 返回地址执行
  uart_stdin_enabled = uart_stdin_requested;                 // 默认关闭, 需要时由 NPC_UART_STDIN=1 打开
}

extern "C" void npc_trap(int a0_val) {
    printf("--------------------------------------\n");
    if (a0_val == 0) {
        printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m\n");   // a0=0 表示 AM 程序正常结束
    } else {
        printf("\033[1;31mNPC: HIT BAD TRAP (Code = %d)\033[0m\n", a0_val); // a0 非 0 表示测试失败
    }
    printf("--------------------------------------\n");
    Verilated::gotFinish(true);                             // 通知 Verilator 主循环应结束
}

void load_img(char *img_file) {
    if (img_file == NULL) {
        printf("警告: 未提供 bin 文件路径！将使用默认的内置测试程序。\n");
        uint32_t built_in_prog[] = {
            0x0000006f // j pc, 没有镜像时让 CPU 原地自旋
        };
        if (flash_boot) {
            memcpy(flash, built_in_prog, sizeof(built_in_prog)); // Flash 启动时把内置程序放到 Flash
        } else {
            memcpy(mrom, built_in_prog, sizeof(built_in_prog));  // MROM 启动时把内置程序放到 MROM
        }
        img_size_loaded = sizeof(built_in_prog);            // 记录内置程序大小
        return;
    }
    FILE *fp = fopen(img_file, "rb");                       // 以二进制方式打开镜像
    assert(fp != NULL);                                     // 镜像不存在时直接停止
    
    fseek(fp, 0, SEEK_END);                                 // 移到文件末尾
    long size = ftell(fp);                                  // 得到文件大小
    fseek(fp, 0, SEEK_SET);                                 // 回到文件开头准备读取

    long capacity = flash_boot ? FLASH_SIZE : MROM_SIZE;    // 根据启动介质选择容量限制
    if (size > capacity) {
        printf("ERROR: 镜像文件太大，无法放入 %s！\n", flash_boot ? "FLASH" : "MROM");
        assert(0);                                          // 镜像超过仿真数组容量, 不能继续
    }
    
    uint8_t *dest = flash_boot ? flash : mrom;              // 选择镜像烧录目标
    size_t ret = fread(dest, size, 1, fp);                  // 一次性读完整个镜像
    assert(ret == 1);                                       // 读取失败说明镜像/文件系统异常
    fclose(fp);                                             // 关闭镜像文件
    img_size_loaded = size;                                 // 保存镜像大小

    printf("成功加载镜像: %s, 大小: %ld bytes (已烧录至 %s)\n", img_file, size, flash_boot ? "FLASH" : "MROM");
}

static uint32_t flash_pattern(uint32_t addr) {
    uint32_t word_addr = addr & ~0x3u;                      // Flash 按 4 字节 word 生成测试 pattern
    return 0x5a000000u ^ (word_addr * 0x01010101u) ^ (word_addr << 8); // 构造一个和地址相关的非零数据
}

void init_flash() {
    memset(flash, 0xff, sizeof(flash));                     // Flash 擦除态通常为 0xff
    for (uint32_t addr = 0; addr < 0x1000; addr += sizeof(uint32_t)) {
        uint32_t data = flash_pattern(addr);                // 前 4KB 填充可识别 pattern, 便于 flash-test
        memcpy(flash + addr, &data, sizeof(data));          // 写入 pattern
    }
}

// =======================================================================
// MROM 读写接口
// =======================================================================
extern "C" void mrom_read(int32_t addr, int32_t *data) { 
    uint32_t uaddr = (uint32_t)addr;                        // DPI 传入有符号 int, 这里按无符号地址解释
    // 检查地址是否在 MROM 范围内
    if (uaddr >= MROM_BASE && uaddr < MROM_BASE + MROM_SIZE) {
        uint32_t offset = uaddr - MROM_BASE;                // 转成 mrom[] 内偏移
        *data = *(uint32_t *)(mrom + offset);               // 返回 32 位小端指令/数据
    } else {
        svSetScope(get_dpi_scope());                        // 为了打印当前 CPU PC, 设置 DPI scope
        printf("\n\033[1;31m[ERROR] 越界读取 MROM 地址: 0x%08x, CPU PC: 0x%08x\033[0m\n", uaddr, npc_read_pc());
        *data = 0;                                          // 越界时返回 0, 同时报警
    }
}

// 这几个函数保持原样，防止后续遇到未定义引用
extern "C" void flash_read(int32_t addr, int32_t *data) { 
    uint32_t uaddr = (uint32_t)addr;                        // Flash DPI 传入的是相对 Flash 基址的偏移
    if (uaddr + sizeof(uint32_t) <= FLASH_SIZE) {
        memcpy(data, flash + uaddr, sizeof(uint32_t));      // 从仿真侧 Flash 数组读 4 字节
    } else {
        printf("\n\033[1;31m[ERROR] 越界读取 FLASH 地址: 0x%08x\033[0m\n", FLASH_BASE + uaddr);
        *data = 0;                                          // 越界时返回 0
    }
}

extern "C" int pmem_read(int raddr) {
    uint32_t uaddr = (uint32_t)raddr;                       // 普通物理内存读取地址
    if (uaddr >= SRAM_BASE && uaddr + sizeof(uint32_t) <= SRAM_BASE + SRAM_SIZE) {
        return *(uint32_t *)(sram + uaddr - SRAM_BASE);     // SRAM 范围内直接读仿真数组
    }
    is_skip_ref = true;                                     // 其他地址可能是 MMIO/SoC 设备, difftest 需要跳过
    return 0;                                               // 当前 pmem 模型不处理这些地址
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
    uint32_t uaddr = (uint32_t)waddr;                       // 普通物理内存写地址
    if (uaddr >= SRAM_BASE && uaddr + sizeof(uint32_t) <= SRAM_BASE + SRAM_SIZE) {
        uint32_t offset = uaddr - SRAM_BASE;                // 转成 sram[] 内偏移
        for (int i = 0; i < 4; i++) {
            if ((wmask >> i) & 0x1) {
                sram[offset + i] = (wdata >> (i * 8)) & 0xff; // 按字节写掩码更新 SRAM
            }
        }
        return;
    }
    is_skip_ref = true;                                     // 非 SRAM 写视为设备/特殊访问, difftest 跳过
}

extern "C" int npc_read_gpr(int idx);

void isa_reg_display(){
    const char* regs[]= {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10","s11","t3","t4","t5","t6"
    };
    printf("------------------NPC Registers------------------\n");
    for(int i=0; i<16; i++){
        uint32_t val = (uint32_t)npc_read_gpr(i);           // 通过 DPI 读取第 i 个寄存器
      printf("%-4s: 0x%08x\t%-10d\n", regs[i], val, val);   // 同时打印十六进制和十进制
    }
    printf("-----------------------------------------------\n");
}

void scan_memory(int n, uint32_t base_addr){
    printf("Scanning memory from 0x%08x:\n", base_addr);
    for(int i=0; i<n; i++){
        uint32_t addr = base_addr + i*4;                    // x 命令按 word 扫描
        uint32_t val = 0;                                   // 默认读值
        if (addr >= MROM_BASE && addr + sizeof(uint32_t) <= MROM_BASE + MROM_SIZE) {
            val = *(uint32_t *)(mrom + addr - MROM_BASE);   // MROM 地址直接查 mrom 数组
        } else {
            val = pmem_read(addr);                          // 其他地址走 pmem_read
        }
        printf("0x%08x: 0x%08x\n", addr, val);
    }
}

void cpu_exec(uint64_t n){
    svSetScope(get_dpi_scope());                            // 执行前设置 DPI scope, 方便读寄存器/PC/commit 信号
    
    while(n > 0){
        if(Verilated::gotFinish()) {
            printf("仿真结束，停止执行。\n");
            break;                                          // trap 或外部结束后退出执行循环
        }
        
        single_cycle();                                     // 推进 DUT 一个周期

        if (npc_is_commit()) {
            perf_insts++;                                   // 只有 RTL 表示提交时才增加动态指令数
#if ENABLE_DIFFTEST
            if(ref_difftest_exec) {
                if (npc_check_skip() || is_skip_ref) {
                    diff_context_t sync_ctx;                // 特殊指令/MMIO 后用 DUT 状态覆盖 REF
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_DUT); // 先拿一个上下文结构
                    for(int i = 0; i < 16; i++) { 
                        sync_ctx.gpr[i] = npc_read_gpr(i);  // 从 DUT 读取每个 GPR
                    }
                    sync_ctx.pc = npc_read_pc();            // 从 DUT 读取 PC
                    
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_REF); // 把 DUT 状态同步给 REF
                    is_skip_ref = false;                    // 清掉 C++ 侧 skip 标记
                } else {
                    diff_context_t ref_ctx;                 // 普通指令走严格逐条比较
                    ref_difftest_exec(1);                   // REF 执行一条指令
                    ref_difftest_regcpy(&ref_ctx, DIFFTEST_TO_DUT); // 读出 REF 寄存器状态
                    checkregs(&ref_ctx);                    // 和 DUT 寄存器比较
                }
            }
#endif
            n--;                                            // 完成一条提交后减少剩余执行条数
        }
    }
}

void sdb_mainloop(){
    char buf[256];                                          // 保存用户输入的一行命令
    while(1){
        printf("(npc) ");
        if(fgets(buf, sizeof(buf), stdin) == NULL) break;   // EOF 时退出调试器
        buf[strcspn(buf, "\n")] = 0;                        // 去掉行尾换行
        char *cmd = strtok(buf, " ");                       // 取第一个 token 作为命令名
        if(cmd == NULL) continue;                           // 空行直接继续
        if(strcmp(cmd, "c") == 0){
            cpu_exec(-1);                                   // c: 连续执行直到 trap/结束
        }else if(strcmp(cmd, "q") == 0){
            break;                                          // q: 退出 SDB
        }else if(strcmp(cmd, "si") == 0){
            char * arg = strtok(NULL, " ");                 // si 后可跟步数
            int steps = (arg == NULL) ? 1 : atoi(arg);      // 默认单步一条提交指令
            cpu_exec(steps);                                // 执行指定条数
        }else if(strcmp(cmd, "info") == 0){
            char * arg = strtok(NULL, " ");                 // info 子命令
            if(arg && strcmp(arg, "r") == 0){
                isa_reg_display();                          // info r: 打印寄存器
            }else{
                printf("Usage: info r\n");
            }
        }else if(strcmp(cmd, "x") == 0){
            char * arg1 = strtok(NULL, " ");                // x 的第一个参数: 扫描 word 数
            char * arg2 = strtok(NULL, " ");                // x 的第二个参数: 起始地址
            if(arg1 && arg2){
                int n = atoi(arg1);                         // 转成整数 word 数
                uint32_t addr ;                             // 起始地址
                sscanf(arg2, "%x", &addr);                  // 按十六进制解析地址
                scan_memory(n, addr);                       // 打印内存内容
            
            }else{
                printf("Usage: x N EXPR\n");
            }
        }else{
            printf("Unknown command: %s\n", cmd);
        }
        if(Verilated::gotFinish()) {
            printf("仿真结束，退出调试器。\n");
            break;                                          // trap 后退出 SDB
        }
    }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);                       // 把命令行参数交给 Verilator 运行时
  uart_debug_enabled = getenv("NPC_UART_DEBUG") != NULL;    // 设置环境变量即可打开 UART RX 调试打印
  uart_stdin_requested = getenv("NPC_UART_STDIN") != NULL;  // 设置环境变量才启用 stdin->UART RX
  const char *pc_trace_path = getenv("NPC_PC_TRACE");       // 可用环境变量指定 PC trace 输出路径
  
  boot_time = get_time_internal();                          // 记录程序启动时间

  char *img_file = NULL;                                    // bin 镜像路径
  char *elf_file = NULL;                                    // ELF 路径, 主要给 ftrace 使用
  bool batch_mode = false;                                  // 是否 batch 自动运行

  for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--batch") == 0) {
          batch_mode = true;                                // -b/--batch: 不进 SDB, 直接跑
      } else if (strcmp(argv[i], "--flash-boot") == 0) {
          flash_boot = true;                                // --flash-boot: 镜像烧到 Flash, reset PC 从 Flash 开始
      } else if (strcmp(argv[i], "--no-difftest") == 0) {
          ref_so_file = NULL;                               // --no-difftest: 不加载 NEMU REF
      } else if (strcmp(argv[i], "--pc-trace") == 0 && i + 1 < argc) {
          pc_trace_path = argv[++i];                        // --pc-trace path: 命令行指定 PC trace 文件
      } else if (img_file == NULL) {
          img_file = argv[i];                               // 第一个非选项参数当作 bin 镜像
      } else if (elf_file == NULL) {
          elf_file = argv[i];                               // 第二个非选项参数当作 ELF
      }
  }

  if (pc_trace_path != NULL && pc_trace_path[0] != '\0') {
      pc_trace_fp = fopen(pc_trace_path, "w");              // 打开 PC trace 输出文件
      if (pc_trace_fp == NULL) {
          perror("open pc trace");
          assert(0);                                        // trace 文件打不开通常是路径/权限问题
      }
      printf("[NPC] PC trace will be written to %s\n", pc_trace_path);
  }

  init_flash();                                             // 初始化 Flash 默认内容
  load_img(img_file);                                       // 加载用户镜像到 MROM 或 Flash

  init_disasm();                                            // 初始化 Capstone, 给 itrace 使用
  init_elf(elf_file);                                       // 加载 ELF 符号表, 给 ftrace 使用

#ifdef ENABLE_NVBOARD
  nvboard_bind_all_pins(&dut);                              // 把 SoC 顶层引脚绑定到 NVBoard 设备
  nvboard_init();                                           // 初始化 NVBoard GUI
#endif
  
  reset(10);                                                // 复位 10 个周期, 满足 SoC/ChipLink 等模块的 reset 需求
  reset_perf_stats();                                       // reset 后再清性能计数, 避免把 reset 周期计入结果
  init_difftest(ref_so_file, img_size_loaded);              // 初始化 REF, 与 DUT 起始状态对齐
  if (batch_mode) {
      printf("\033[1;36m[NPC] 运行在 Batch 模式 (自动执行)...\033[0m\n");
      cpu_exec(-1);                                         // batch 模式一直执行到 trap/finish
  } else {
      printf("\033[1;36m[NPC] 运行在 SDB 模式 (交互调试)...\033[0m\n");
      sdb_mainloop();                                       // 非 batch 模式进入简易调试器
  }

  print_perf_stats();                                       // 仿真结束后统一打印性能统计

  if (pc_trace_fp != NULL) {
      fclose(pc_trace_fp);                                  // 关闭 PC trace 文件
      pc_trace_fp = NULL;                                   // 防止悬空文件指针
  }

#ifdef ENABLE_NVBOARD
  nvboard_quit();                                           // 释放 NVBoard GUI 资源
#endif
  
  return 0;                                                 // 正常退出仿真程序
}
