/*#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <nvboard.h>
#include <Vexample.h>
#include "verilated.h"
#include <sys/time.h>
#include <capstone/capstone.h>
#include <libelf.h>
#include <gelf.h>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <dlfcn.h>

extern "C" int npc_read_gpr(int idx);
extern "C" uint32_t npc_read_pc();

bool is_skip_ref = false;

static Vexample dut;
#define MEM_SIZE 0x4000000
uint8_t mem[MEM_SIZE];

#define RTC_ADDR 0xa0000048
#define SERIAL_PORT 0x10000000
#define MEM_BASE 0x80000000

#define ENABLE_ITRACE 0
#define ENABLE_MTRACE 0
#define ENABLE_FTRACE 0
#define ENABLE_DIFFTEST 1// 开关

// 类型补全
typedef uint32_t paddr_t;
typedef uint32_t word_t;

enum {DIFFTEST_TO_DUT, DIFFTEST_TO_REF};

typedef struct {
    char name[128];
    uint32_t addr;
    uint32_t size;
} Symbol;

struct diff_context_t {
    uint32_t gpr[16];
    uint32_t pc;
    uint32_t csr[4];
};
void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(word_t NO) = NULL;
void (*ref_difftest_init)(int port) = NULL;


std::vector<Symbol> symbol_table;
int  call_depth = 0;

void init_elf(const char *elf_file) {
    if(elf_file == NULL)return;
    int fd = open(elf_file, O_RDONLY);
    if(fd < 0){perror("open elf"); return;}
    elf_version(EV_CURRENT);
    Elf *e = elf_begin(fd, ELF_C_READ, NULL);
    Elf_Scn *scn = NULL;
    GElf_Shdr shdr;
    while((scn = elf_nextscn(e, scn)) != NULL) {
        gelf_getshdr(scn, &shdr);
        if(shdr.sh_type == SHT_SYMTAB) {
            Elf_Data *data = elf_getdata(scn, NULL);
            int count = shdr.sh_size / shdr.sh_entsize;
            for(int i = 0; i < count; i++) {
                GElf_Sym sym;
                gelf_getsym(data, i, &sym);
                if(GELF_ST_TYPE(sym.st_info) == STT_FUNC && sym.st_size > 0) {
                    Symbol s;
                    strncpy(s.name, elf_strptr(e, shdr.sh_link, sym.st_name),127);
                    s.addr = sym.st_value;
                    s.size = sym.st_size;
                    symbol_table.push_back(s);
                }
            }
        }
    }
    elf_end(e);
    close(fd);
    printf("FTRACE: Loaded %ld symbols from %s\n", symbol_table.size(), elf_file);
}

const char* find_symbol(uint32_t addr){
    for(auto &s : symbol_table){
        if(addr >= s.addr && addr < s.addr + s.size){
            return s.name;
        }
    }
    return NULL;
}

void ftrace_print(uint32_t pc, uint32_t target, bool is_call){
    if(!ENABLE_FTRACE) return;
    const char* func_name = find_symbol(target);
    printf("\033[1;34m[FTRACE]\033[0m");
    for(int i = 0; i < call_depth; i++) printf("  ");
    if(is_call){
        printf("0x%08x: call [%s@0x%08x]\n", pc, func_name ? func_name : "???", target);
        call_depth++;
    }else{
        call_depth--;
        if(call_depth < 0) call_depth = 0;
        printf("0x%08x: ret  [%s]\n", pc, func_name ? func_name : "???");
    }
}


static csh capstone_handle;
static bool capstone_initialized = false;

void init_disasm() {
    cs_err err = cs_open(CS_ARCH_RISCV, CS_MODE_RISCV32, &capstone_handle);
    if (err != CS_ERR_OK) {
        // 打印具体的错误字符串
        printf("ERROR: Capstone init failed: %s\n", cs_strerror(err));
        return;
    }
    capstone_initialized = true;
    printf("Capstone initialized successfully.\n"); // 添加一行确认信息
}


extern "C" void npc_itrace_commit(uint32_t pc, uint32_t inst, uint32_t dnpc) {
    // ---------------------------------------------------------
    // 1. 纯 ITRACE 逻辑 (依赖 Capstone)
    // ---------------------------------------------------------
    #if ENABLE_ITRACE
    if (capstone_initialized) {
        cs_insn* insn;
        size_t count = cs_disasm(capstone_handle, (const uint8_t*)&inst, 4, pc, 0, &insn);
        if (count > 0) {
            printf("[ITRACE] 0x%08x: %08x    %-7s %s\n", pc, inst, insn[0].mnemonic, insn[0].op_str);
            cs_free(insn, count);
        } else {
            printf("[ITRACE] 0x%08x: %08x    (Unknown Instruction)\n", pc, inst);
        }
    }
    #endif

    // ---------------------------------------------------------
    // 2. 纯 FTRACE 逻辑 (独立运行，不依赖 Capstone)
    // ---------------------------------------------------------
    #if ENABLE_FTRACE
    // RISC-V 32I 指令解码 (硬编码位操作)
    uint32_t opcode = inst & 0x7F;           // 最低 7 位
    uint32_t rd     = (inst >> 7) & 0x1F;    // 目标寄存器 (7-11 位)
    uint32_t rs1    = (inst >> 15) & 0x1F;   // 源寄存器 1 (15-19 位)

    bool is_jal  = (opcode == 0x6F);         // JAL (1101111)
    bool is_jalr = (opcode == 0x67);         // JALR (1100111)

    // 判断 Call: jal 或 jalr，且目标寄存器是 ra (x1)
    if ((is_jal || is_jalr) && (rd == 1)) {
        ftrace_print(pc, dnpc, true);
    }
    // 判断 Ret: jalr，且源寄存器是 ra (x1)，目标寄存器是 zero (x0)
    else if (is_jalr && (rs1 == 1) && (rd == 0)) {
        ftrace_print(pc, dnpc, false);
    }
    #endif
}

void init_difftest(const char *ref_so_file, long img_size) {
#if ENABLE_DIFFTEST
    if(ref_so_file == NULL){
        printf("WARNING: No reference shared object provided for difftest! Running in pure simulation mode.\n");
        return;
    }
    void *handle = dlopen(ref_so_file, RTLD_LAZY);
    assert(handle);
    ref_difftest_memcpy = (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
    ref_difftest_regcpy = (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");
    ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
    ref_difftest_init = (void (*)(int))dlsym(handle, "difftest_init");
    assert(ref_difftest_memcpy && ref_difftest_regcpy && ref_difftest_exec && ref_difftest_init);
    svSetScope(svGetScopeFromName("TOP.example"));
    ref_difftest_init(0);
    ref_difftest_memcpy(MEM_BASE, mem, img_size, DIFFTEST_TO_REF);
    diff_context_t ctx ;
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT); 
    // 2. 只修改我们需要对齐的 PC 和通用寄存器
    ctx.pc = MEM_BASE;
    for(int i = 0; i < 16; i++) {
        ctx.gpr[i] = npc_read_gpr(i); // 对齐硬件的初始 GPR
    }
    // 3. 原封不动地把包含 0x1800 的 CSR 连同新 PC 一起写回 NEMU
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_REF);
   
    printf("DiffTest initialized with %s\n", ref_so_file);
#endif
}
void checkregs(diff_context_t * ref) {
    bool mismatch = false;
    for(int i = 0; i < 16; i++){
        
            if(npc_read_gpr(i) != ref->gpr[i]) {
                mismatch = true;
                printf("Register x%d mismatch: NPC=0x%08x, REF=0x%08x\n", i, npc_read_gpr(i), ref->gpr[i]);
            }
        }
    if(mismatch) {
      printf("DiffTest failed at PC = 0x%08x\n", ref->pc);
      assert(0);
    }
}

static uint64_t boot_time = 0;
static uint64_t get_time_internal(){
    struct timeval now;
    gettimeofday(&now, NULL);
    return now.tv_sec * 1000000ull + now.tv_usec;
}


void nvboard_bind_all_pins(Vexample* top);

void single_cycle() {
  dut.clk = 0;dut.eval();
  dut.clk = 1;dut.eval();
}

void reset(int n) {
  dut.rst = 1;
  while(n-- >0) single_cycle();
  dut.rst = 0;
}

extern "C" void npc_trap(int a0_val) {
    printf("--------------------------------------\n");
    if (a0_val == 0) {
        printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m\n"); // 绿色打印
    } else {
        printf("\033[1;31mNPC: HIT BAD TRAP (Code = %d)\033[0m\n", a0_val); // 红色打印
    }
    printf("--------------------------------------\n");
    // 通知 Verilator 改变内部状态，表示仿真应该结束了
    Verilated::gotFinish(true);
}

void load_img(char *img_file) {
    if (img_file == NULL) {
        printf("警告: 未提供 bin 文件路径！将使用默认的内置测试程序。\n");
        // 内置测试程序：addi x1, x0, 5 -> addi x2, x1, 10 -> ebreak
        uint32_t built_in_prog[] = {
            0x00500093, 
            0x00A08113, 
            0x00100073  
        };
        memcpy(mem, built_in_prog, sizeof(built_in_prog));
        return;
    }
    char *so_file  = "/home/vboxuser/clip/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so";
    FILE *fp = fopen(img_file, "rb");
    assert(fp != NULL); // 如果文件打不开，直接报错退出
    
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    
    size_t ret = fread(mem, size, 1, fp);
    assert(ret == 1);
    fclose(fp);
    init_difftest(so_file, size);

    printf("成功加载镜像: %s, 大小: %ld bytes\n", img_file, size);
}

extern "C" int pmem_read(int raddr) {
    if(raddr == RTC_ADDR){
        is_skip_ref = true;
        uint64_t us = get_time_internal() - boot_time;
        return (uint32_t)us;
    }
    if(raddr == RTC_ADDR + 4){
        is_skip_ref = true;
        uint64_t us = get_time_internal() - boot_time;
        return (uint32_t)(us >> 32);
    }
    int paddr = raddr - 0x80000000;

    
    // 越界检查防崩溃
    if (paddr < 0 || paddr >= MEM_SIZE) return 0;
    
    // 总是读取对齐的 4 字节
    uint32_t data =  *(uint32_t *)(mem + paddr);

    #if ENABLE_MTRACE
    // 只有非取指（通过 PC 判断）或特定地址才打印会更清晰
    printf("[MTRACE] read  addr: 0x%08x, data: 0x%08x\n", raddr, data);
    #endif
    return data;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
   if(waddr == SERIAL_PORT){
    putchar((char)wdata & 0xFF);
    fflush(stdout);
    is_skip_ref = true;
    return;
   }

   #if ENABLE_MTRACE
    printf("[MTRACE] write addr: 0x%08x, data: 0x%08x, mask: 0x%02x\n", waddr, wdata, (uint8_t)wmask);
    #endif
   waddr = waddr & ~0x3u;

   int paddr = waddr - 0x80000000;
    if (paddr < 0 || paddr >= MEM_SIZE) return;
    
    // 根据 wmask 按字节写入
    for (int i = 0; i < 4; i++) {
        if ((wmask >> i) & 1) {
            *(uint8_t *)(mem + paddr + i) = (uint8_t)(wdata >> (i * 8));
        }
    }
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
        uint32_t val = (uint32_t)npc_read_gpr(i);
      printf("%-4s: 0x%08x\t%-10d\n", regs[i], val, val);
    }
    printf("-----------------------------------------------\n");
}

void scan_memory(int n, uint32_t base_addr){
    printf("Scanning memory from 0x%08x:\n", base_addr);
    for(int i=0; i<n; i++){
        uint32_t addr = base_addr + i*4;
        uint32_t val = pmem_read(addr);
        printf("0x%08x: 0x%08x\n", addr, val);
    }
}

void cpu_exec(uint64_t n){
    static svScope scope = svGetScopeFromName("TOP.example"); // 名字通常是 TOP.顶层模块名
    svSetScope(scope);
    for(; n > 0; n--){
        if(Verilated::gotFinish()) {
            printf("仿真结束，停止执行。\n");
            break;
        }
        //nvboard_update();
        single_cycle();
#if ENABLE_DIFFTEST
   if(ref_difftest_exec) {
    if (is_skip_ref) {
                // 如果访问了设备，强制把 NPC 的状态（寄存器+PC）复制给 NEMU

                diff_context_t sync_ctx;
                ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_DUT);
                for(int i = 0; i < 16; i++) { // RV32E 是 16 个
                    sync_ctx.gpr[i] = npc_read_gpr(i);
                }
                sync_ctx.pc = npc_read_pc(); // 拿到 NPC 的当前 PC
                
                ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_REF); // TO_REF!
                is_skip_ref = false; // 用完重置
            } else {
                // 正常执行
                diff_context_t ref_ctx;
                ref_difftest_exec(1); 
                ref_difftest_regcpy(&ref_ctx, DIFFTEST_TO_DUT); 
                checkregs(&ref_ctx); 
            }
   }
#endif
    }
}

void sdb_mainloop(){
    char buf[256];
    while(1){
        printf("(npc) ");
        if(fgets(buf, sizeof(buf), stdin) == NULL) break;
        buf[strcspn(buf, "\n")] = 0; // 去掉换行符
        char *cmd = strtok(buf, " ");
        if(cmd == NULL) continue;
        if(strcmp(cmd, "c") == 0){
            cpu_exec(-1);
        }else if(strcmp(cmd, "q") == 0){
            break;
        }else if(strcmp(cmd, "si") == 0){
            char * arg = strtok(NULL, " ");
            int steps = (arg == NULL) ? 1 : atoi(arg);
            cpu_exec(steps);
        }else if(strcmp(cmd, "info") == 0){
            char * arg = strtok(NULL, " ");
            if(arg && strcmp(arg, "r") == 0){
                isa_reg_display();
            }else{
                printf("Usage: info r\n");
            }
        }else if(strcmp(cmd, "x") == 0){
            char * arg1 = strtok(NULL, " ");
            char * arg2 = strtok(NULL, " ");
            if(arg1 && arg2){
                int n = atoi(arg1);
                uint32_t addr ;
                sscanf(arg2, "%x", &addr);
                scan_memory(n, addr);
           
            }else{
                printf("Usage: x N EXPR\n");
            }
        }else{
            printf("Unknown command: %s\n", cmd);
        }
        if(Verilated::gotFinish()) {
            printf("仿真结束，退出调试器。\n");
            break;
        }
    }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  boot_time = get_time_internal();

  char *img_file = NULL;
  char *elf_file = NULL;
  if (argc >= 3) {
        elf_file = argv[2];
    }
  if (argc >= 2) {
      img_file = argv[1];
  }
  load_img(img_file);

  init_disasm();
  init_elf(elf_file);
  //nvboard_bind_all_pins(&dut);
  //nvboard_init();
  reset(10);
  sdb_mainloop();

  
  //nvboard_quit();
  return 0;
}*/
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <nvboard.h>
#include <Vexample.h>
#include "verilated.h"
#include <sys/time.h>
#include <capstone/capstone.h>
#include <libelf.h>
#include <gelf.h>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <dlfcn.h>

extern "C" int npc_read_gpr(int idx);
extern "C" uint32_t npc_read_pc();
// --- 新增：查询 NPC 当前周期是否有效提交了指令 ---
extern "C" int npc_is_commit(); 

bool is_skip_ref = false;

static Vexample dut;
#define MEM_SIZE 0x4000000
uint8_t mem[MEM_SIZE];

#define RTC_ADDR 0xa0000048
#define SERIAL_PORT 0x10000000
#define MEM_BASE 0x80000000

#define ENABLE_ITRACE 0
#define ENABLE_MTRACE 0
#define ENABLE_FTRACE 0
#define ENABLE_DIFFTEST 1// 开关

// 类型补全
typedef uint32_t paddr_t;
typedef uint32_t word_t;

enum {DIFFTEST_TO_DUT, DIFFTEST_TO_REF};

typedef struct {
    char name[128];
    uint32_t addr;
    uint32_t size;
} Symbol;

struct diff_context_t {
    uint32_t gpr[16];
    uint32_t pc;
    uint32_t csr[4];
};
void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(word_t NO) = NULL;
void (*ref_difftest_init)(int port) = NULL;


std::vector<Symbol> symbol_table;
int  call_depth = 0;

void init_elf(const char *elf_file) {
    if(elf_file == NULL)return;
    int fd = open(elf_file, O_RDONLY);
    if(fd < 0){perror("open elf"); return;}
    elf_version(EV_CURRENT);
    Elf *e = elf_begin(fd, ELF_C_READ, NULL);
    Elf_Scn *scn = NULL;
    GElf_Shdr shdr;
    while((scn = elf_nextscn(e, scn)) != NULL) {
        gelf_getshdr(scn, &shdr);
        if(shdr.sh_type == SHT_SYMTAB) {
            Elf_Data *data = elf_getdata(scn, NULL);
            int count = shdr.sh_size / shdr.sh_entsize;
            for(int i = 0; i < count; i++) {
                GElf_Sym sym;
                gelf_getsym(data, i, &sym);
                if(GELF_ST_TYPE(sym.st_info) == STT_FUNC && sym.st_size > 0) {
                    Symbol s;
                    strncpy(s.name, elf_strptr(e, shdr.sh_link, sym.st_name),127);
                    s.addr = sym.st_value;
                    s.size = sym.st_size;
                    symbol_table.push_back(s);
                }
            }
        }
    }
    elf_end(e);
    close(fd);
    printf("FTRACE: Loaded %ld symbols from %s\n", symbol_table.size(), elf_file);
}

const char* find_symbol(uint32_t addr){
    for(auto &s : symbol_table){
        if(addr >= s.addr && addr < s.addr + s.size){
            return s.name;
        }
    }
    return NULL;
}

void ftrace_print(uint32_t pc, uint32_t target, bool is_call){
    if(!ENABLE_FTRACE) return;
    const char* func_name = find_symbol(target);
    printf("\033[1;34m[FTRACE]\033[0m");
    for(int i = 0; i < call_depth; i++) printf("  ");
    if(is_call){
        printf("0x%08x: call [%s@0x%08x]\n", pc, func_name ? func_name : "???", target);
        call_depth++;
    }else{
        call_depth--;
        if(call_depth < 0) call_depth = 0;
        printf("0x%08x: ret  [%s]\n", pc, func_name ? func_name : "???");
    }
}


static csh capstone_handle;
static bool capstone_initialized = false;

void init_disasm() {
    cs_err err = cs_open(CS_ARCH_RISCV, CS_MODE_RISCV32, &capstone_handle);
    if (err != CS_ERR_OK) {
        // 打印具体的错误字符串
        printf("ERROR: Capstone init failed: %s\n", cs_strerror(err));
        return;
    }
    capstone_initialized = true;
    printf("Capstone initialized successfully.\n"); // 添加一行确认信息
}


extern "C" void npc_itrace_commit(uint32_t pc, uint32_t inst, uint32_t dnpc) {
    // ---------------------------------------------------------
    // 1. 纯 ITRACE 逻辑 (依赖 Capstone)
    // ---------------------------------------------------------
    #if ENABLE_ITRACE
    if (capstone_initialized) {
        cs_insn* insn;
        size_t count = cs_disasm(capstone_handle, (const uint8_t*)&inst, 4, pc, 0, &insn);
        if (count > 0) {
            printf("[ITRACE] 0x%08x: %08x    %-7s %s\n", pc, inst, insn[0].mnemonic, insn[0].op_str);
            cs_free(insn, count);
        } else {
            printf("[ITRACE] 0x%08x: %08x    (Unknown Instruction)\n", pc, inst);
        }
    }
    #endif

    // ---------------------------------------------------------
    // 2. 纯 FTRACE 逻辑 (独立运行，不依赖 Capstone)
    // ---------------------------------------------------------
    #if ENABLE_FTRACE
    // RISC-V 32I 指令解码 (硬编码位操作)
    uint32_t opcode = inst & 0x7F;           // 最低 7 位
    uint32_t rd     = (inst >> 7) & 0x1F;    // 目标寄存器 (7-11 位)
    uint32_t rs1    = (inst >> 15) & 0x1F;   // 源寄存器 1 (15-19 位)

    bool is_jal  = (opcode == 0x6F);         // JAL (1101111)
    bool is_jalr = (opcode == 0x67);         // JALR (1100111)

    // 判断 Call: jal 或 jalr，且目标寄存器是 ra (x1)
    if ((is_jal || is_jalr) && (rd == 1)) {
        ftrace_print(pc, dnpc, true);
    }
    // 判断 Ret: jalr，且源寄存器是 ra (x1)，目标寄存器是 zero (x0)
    else if (is_jalr && (rs1 == 1) && (rd == 0)) {
        ftrace_print(pc, dnpc, false);
    }
    #endif
}

void init_difftest(const char *ref_so_file, long img_size) {
#if ENABLE_DIFFTEST
    if(ref_so_file == NULL){
        printf("WARNING: No reference shared object provided for difftest! Running in pure simulation mode.\n");
        return;
    }
    void *handle = dlopen(ref_so_file, RTLD_LAZY);
    assert(handle);
    ref_difftest_memcpy = (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
    ref_difftest_regcpy = (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");
    ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
    ref_difftest_init = (void (*)(int))dlsym(handle, "difftest_init");
    assert(ref_difftest_memcpy && ref_difftest_regcpy && ref_difftest_exec && ref_difftest_init);
    svSetScope(svGetScopeFromName("TOP.example"));
    ref_difftest_init(0);
    ref_difftest_memcpy(MEM_BASE, mem, img_size, DIFFTEST_TO_REF);
    diff_context_t ctx ;
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT); 
    // 2. 只修改我们需要对齐的 PC 和通用寄存器
    ctx.pc = MEM_BASE;
    for(int i = 0; i < 16; i++) {
        ctx.gpr[i] = npc_read_gpr(i); // 对齐硬件的初始 GPR
    }
    // 3. 原封不动地把包含 0x1800 的 CSR 连同新 PC 一起写回 NEMU
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_REF);
   
    printf("DiffTest initialized with %s\n", ref_so_file);
#endif
}
void checkregs(diff_context_t * ref) {
    bool mismatch = false;
    for(int i = 0; i < 16; i++){
        
            if(npc_read_gpr(i) != ref->gpr[i]) {
                mismatch = true;
                printf("Register x%d mismatch: NPC=0x%08x, REF=0x%08x\n", i, npc_read_gpr(i), ref->gpr[i]);
            }
        }
    if(mismatch) {
      printf("DiffTest failed at PC = 0x%08x\n", ref->pc);
      assert(0);
    }
}

static uint64_t boot_time = 0;
static uint64_t get_time_internal(){
    struct timeval now;
    gettimeofday(&now, NULL);
    return now.tv_sec * 1000000ull + now.tv_usec;
}


void nvboard_bind_all_pins(Vexample* top);

void single_cycle() {
  dut.clk = 0;dut.eval();
  dut.clk = 1;dut.eval();
}

void reset(int n) {
  dut.rst = 1;
  while(n-- >0) single_cycle();
  dut.rst = 0;
}

extern "C" void npc_trap(int a0_val) {
    printf("--------------------------------------\n");
    if (a0_val == 0) {
        printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m\n"); // 绿色打印
    } else {
        printf("\033[1;31mNPC: HIT BAD TRAP (Code = %d)\033[0m\n", a0_val); // 红色打印
    }
    printf("--------------------------------------\n");
    // 通知 Verilator 改变内部状态，表示仿真应该结束了
    Verilated::gotFinish(true);
}

void load_img(char *img_file) {
    if (img_file == NULL) {
        printf("警告: 未提供 bin 文件路径！将使用默认的内置测试程序。\n");
        // 内置测试程序：addi x1, x0, 5 -> addi x2, x1, 10 -> ebreak
        uint32_t built_in_prog[] = {
            0x00500093, 
            0x00A08113, 
            0x00100073  
        };
        memcpy(mem, built_in_prog, sizeof(built_in_prog));
        return;
    }
    char *so_file  = "/home/vboxuser/clip/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so";
    FILE *fp = fopen(img_file, "rb");
    assert(fp != NULL); // 如果文件打不开，直接报错退出
    
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    
    size_t ret = fread(mem, size, 1, fp);
    assert(ret == 1);
    fclose(fp);
    init_difftest(so_file, size);

    printf("成功加载镜像: %s, 大小: %ld bytes\n", img_file, size);
}

extern "C" int pmem_read(int raddr) {
    if(raddr == RTC_ADDR){
        is_skip_ref = true;
        uint64_t us = get_time_internal() - boot_time;
        return (uint32_t)us;
    }
    if(raddr == RTC_ADDR + 4){
        is_skip_ref = true;
        uint64_t us = get_time_internal() - boot_time;
        return (uint32_t)(us >> 32);
    }
    int paddr = raddr - 0x80000000;

    
    // 越界检查防崩溃
    if (paddr < 0 || paddr >= MEM_SIZE) return 0;
    
    // 总是读取对齐的 4 字节
    uint32_t data =  *(uint32_t *)(mem + paddr);

    #if ENABLE_MTRACE
    // 只有非取指（通过 PC 判断）或特定地址才打印会更清晰
    printf("[MTRACE] read  addr: 0x%08x, data: 0x%08x\n", raddr, data);
    #endif
    return data;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
   if(waddr == SERIAL_PORT){
    putchar((char)wdata & 0xFF);
    fflush(stdout);
    is_skip_ref = true;
    return;
   }

   #if ENABLE_MTRACE
    printf("[MTRACE] write addr: 0x%08x, data: 0x%08x, mask: 0x%02x\n", waddr, wdata, (uint8_t)wmask);
    #endif
   waddr = waddr & ~0x3u;

   int paddr = waddr - 0x80000000;
    if (paddr < 0 || paddr >= MEM_SIZE) return;
    
    // 根据 wmask 按字节写入
    for (int i = 0; i < 4; i++) {
        if ((wmask >> i) & 1) {
            *(uint8_t *)(mem + paddr + i) = (uint8_t)(wdata >> (i * 8));
        }
    }
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
        uint32_t val = (uint32_t)npc_read_gpr(i);
      printf("%-4s: 0x%08x\t%-10d\n", regs[i], val, val);
    }
    printf("-----------------------------------------------\n");
}

void scan_memory(int n, uint32_t base_addr){
    printf("Scanning memory from 0x%08x:\n", base_addr);
    for(int i=0; i<n; i++){
        uint32_t addr = base_addr + i*4;
        uint32_t val = pmem_read(addr);
        printf("0x%08x: 0x%08x\n", addr, val);
    }
}

void cpu_exec(uint64_t n){
    static svScope scope = svGetScopeFromName("TOP.example"); // 名字通常是 TOP.顶层模块名
    svSetScope(scope);
    
    // --- 核心修改：将 for 改为 while，按“有效指令”扣减进度 ---
    while(n > 0){
        if(Verilated::gotFinish()) {
            printf("仿真结束，停止执行。\n");
            break;
        }
        
        // 1. 让硬件走过一个时钟周期
        single_cycle();

        // 2. 判断该周期是否为有效提交周期（NPC 处于 WAIT 状态且非 Stall）
        if (npc_is_commit()) {
#if ENABLE_DIFFTEST
            if(ref_difftest_exec) {
                if (is_skip_ref) {
                    // 如果访问了设备，强制把 NPC 的状态（寄存器+PC）复制给 NEMU
                    diff_context_t sync_ctx;
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_DUT);
                    for(int i = 0; i < 16; i++) { // RV32E 是 16 个
                        sync_ctx.gpr[i] = npc_read_gpr(i);
                    }
                    sync_ctx.pc = npc_read_pc(); // 拿到 NPC 的当前 PC
                    
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_REF); // TO_REF!
                    is_skip_ref = false; // 用完重置
                } else {
                    // 正常执行
                    diff_context_t ref_ctx;
                    ref_difftest_exec(1); 
                    ref_difftest_regcpy(&ref_ctx, DIFFTEST_TO_DUT); 
                    checkregs(&ref_ctx); 
                }
            }
#endif
            // 3. 只有真正提交了指令，才扣减目标执行数
            n--;
        }
    }
}

void sdb_mainloop(){
    char buf[256];
    while(1){
        printf("(npc) ");
        if(fgets(buf, sizeof(buf), stdin) == NULL) break;
        buf[strcspn(buf, "\n")] = 0; // 去掉换行符
        char *cmd = strtok(buf, " ");
        if(cmd == NULL) continue;
        if(strcmp(cmd, "c") == 0){
            cpu_exec(-1);
        }else if(strcmp(cmd, "q") == 0){
            break;
        }else if(strcmp(cmd, "si") == 0){
            char * arg = strtok(NULL, " ");
            int steps = (arg == NULL) ? 1 : atoi(arg);
            cpu_exec(steps);
        }else if(strcmp(cmd, "info") == 0){
            char * arg = strtok(NULL, " ");
            if(arg && strcmp(arg, "r") == 0){
                isa_reg_display();
            }else{
                printf("Usage: info r\n");
            }
        }else if(strcmp(cmd, "x") == 0){
            char * arg1 = strtok(NULL, " ");
            char * arg2 = strtok(NULL, " ");
            if(arg1 && arg2){
                int n = atoi(arg1);
                uint32_t addr ;
                sscanf(arg2, "%x", &addr);
                scan_memory(n, addr);
            
            }else{
                printf("Usage: x N EXPR\n");
            }
        }else{
            printf("Unknown command: %s\n", cmd);
        }
        if(Verilated::gotFinish()) {
            printf("仿真结束，退出调试器。\n");
            break;
        }
    }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  boot_time = get_time_internal();


  char *img_file = NULL;
  char *elf_file = NULL;
  bool batch_mode = true;
  if (argc >= 3) {
        elf_file = argv[2];
    }
  if (argc >= 2) {
      img_file = argv[1];
  }
  load_img(img_file);

  init_disasm();
  init_elf(elf_file);
  //nvboard_bind_all_pins(&dut);
  //nvboard_init();
  reset(10);
  if (batch_mode) {
      printf("\033[1;36m[NPC] 运行在 Batch 模式 (自动执行)...\033[0m\n");
      cpu_exec(-1); // 直接执行到底，不进 SDB
  } else {
      printf("\033[1;36m[NPC] 运行在 SDB 模式 (交互调试)...\033[0m\n");
      sdb_mainloop(); // 进入你的调试器
  }


  
  //nvboard_quit();
  return 0;
}

