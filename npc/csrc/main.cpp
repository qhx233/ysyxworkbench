/*
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <nvboard.h>
#include <VysyxSoCFull.h>
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
extern "C" int npc_is_commit(); 
extern "C" int npc_check_skip();

bool is_skip_ref = false;

static VysyxSoCFull dut;

// =======================================================================
// MROM 定义 (0x2000_0000 ~ 0x2000_0fff)
// =======================================================================
#define MROM_SIZE 0x1000 
uint8_t mrom[MROM_SIZE];
#define MROM_BASE 0x20000000

#define ENABLE_ITRACE 0
#define ENABLE_MTRACE 0
#define ENABLE_FTRACE 0
#define ENABLE_DIFFTEST 0

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

// =======================================================================
// 自动获取正确的 DPI-C 作用域 (智能匹配常见路径)
// =======================================================================
svScope get_dpi_scope() {
    static svScope scope = NULL;
    if (scope == NULL) {
        const char* possible_scopes[] = {
            "TOP.ysyxSoCFull.asic.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_23060000",
            "TOP.ysyxSoCFull.cpu.cpu",
            "TOP.ysyxSoCFull.cpu",
            "TOP.ysyxSoCFull.asic.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.ysyx_23060000",
            "TOP.ysyxSoCFull.ysyx_00000000",
            "TOP.ysyxSoCFull.ysyx_23060000"
        };
        for (int i = 0; i < 10; i++) {
            scope = svGetScopeFromName(possible_scopes[i]);
            if (scope) {
                printf("\033[1;32m[NPC] 成功匹配到 DPI-C 作用域: %s\033[0m\n", possible_scopes[i]);
                break;
            }
        }
        if (!scope) {
            printf("\n\033[1;31m[ERROR] 所有的预设作用域都未找到！\033[0m\n");
            printf("请在终端运行: grep -r \"svGetScopeFromName\" build/obj_dir/ 来查看真实的路径。\n");
            assert(0);
        }
    }
    return scope;
}

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
        printf("ERROR: Capstone init failed: %s\n", cs_strerror(err));
        return;
    }
    capstone_initialized = true;
    printf("Capstone initialized successfully.\n");
}

extern "C" void npc_itrace_commit(uint32_t pc, uint32_t inst, uint32_t dnpc) {
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

    #if ENABLE_FTRACE
    uint32_t opcode = inst & 0x7F;           
    uint32_t rd     = (inst >> 7) & 0x1F;    
    uint32_t rs1    = (inst >> 15) & 0x1F;   

    bool is_jal  = (opcode == 0x6F);         
    bool is_jalr = (opcode == 0x67);         

    if ((is_jal || is_jalr) && (rd == 1)) {
        ftrace_print(pc, dnpc, true);
    }
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
    
    svSetScope(get_dpi_scope());
    
    ref_difftest_init(0);
    // 现在将镜像拷贝到 MROM 基地址，以供 DiffTest 使用
    ref_difftest_memcpy(MROM_BASE, mrom, img_size, DIFFTEST_TO_REF);
    diff_context_t ctx ;
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT); 
    ctx.pc = MROM_BASE;
    for(int i = 0; i < 16; i++) {
        ctx.gpr[i] = npc_read_gpr(i); 
    }
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

void single_cycle() {
  dut.clock = 0;dut.eval();
  dut.clock = 1;dut.eval();
}

void reset(int n) {
  dut.reset = 1;
  while(n-- >0) single_cycle();
  dut.reset = 0;
}

extern "C" void npc_trap(int a0_val) {
    printf("--------------------------------------\n");
    if (a0_val == 0) {
        printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m\n"); 
    } else {
        printf("\033[1;31mNPC: HIT BAD TRAP (Code = %d)\033[0m\n", a0_val); 
    }
    printf("--------------------------------------\n");
    Verilated::gotFinish(true);
}

void load_img(char *img_file) {
    if (img_file == NULL) {
        printf("警告: 未提供 bin 文件路径！将使用默认的内置测试程序。\n");
        // 如果没有提供 bin 文件，我们在 MROM 中放一条跳转到自身的死循环指令
        uint32_t built_in_prog[] = {
            0x0000006f // j pc
        };
        memcpy(mrom, built_in_prog, sizeof(built_in_prog));
        return;
    }
    char *so_file  = "/home/vboxuser/clip/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so";
    FILE *fp = fopen(img_file, "rb");
    assert(fp != NULL); 
    
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (size > MROM_SIZE) {
        printf("ERROR: 镜像文件太大，无法放入 MROM！\n");
        assert(0);
    }
    
    // 【修改点】：将镜像文件读入 mrom 数组
    size_t ret = fread(mrom, size, 1, fp);
    assert(ret == 1);
    fclose(fp);
    init_difftest(so_file, size);

    printf("成功加载镜像: %s, 大小: %ld bytes (已烧录至 MROM)\n", img_file, size);
}

// =======================================================================
// MROM 读写接口
// =======================================================================
extern "C" void mrom_read(int32_t addr, int32_t *data) { 
    uint32_t uaddr = (uint32_t)addr;
    // 检查地址是否在 MROM 范围内
    if (uaddr >= MROM_BASE && uaddr < MROM_BASE + MROM_SIZE) {
        uint32_t offset = uaddr - MROM_BASE;
        *data = *(uint32_t *)(mrom + offset);
    } else {
        printf("\n\033[1;31m[ERROR] 越界读取 MROM 地址: 0x%08x\033[0m\n", uaddr);
        *data = 0;
    }
}

// 这几个函数保持原样，防止后续遇到未定义引用
extern "C" void flash_read(int32_t addr, int32_t *data) { 
    assert(0); 
}

extern "C" int pmem_read(int raddr) {
    is_skip_ref = true;
    return 0; 
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
   is_skip_ref = true;
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
        uint32_t val = pmem_read(addr); // 注意，如果你想看 MROM，这里要改成调用 mrom 数组
        printf("0x%08x: 0x%08x\n", addr, val);
    }
}

void cpu_exec(uint64_t n){
    svSetScope(get_dpi_scope());
    
    while(n > 0){
        if(Verilated::gotFinish()) {
            printf("仿真结束，停止执行。\n");
            break;
        }
        
        single_cycle();

        if (npc_is_commit()) {
#if ENABLE_DIFFTEST
            if(ref_difftest_exec) {
                if (npc_check_skip() || is_skip_ref) {
                    diff_context_t sync_ctx;
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_DUT);
                    for(int i = 0; i < 16; i++) { 
                        sync_ctx.gpr[i] = npc_read_gpr(i);
                    }
                    sync_ctx.pc = npc_read_pc(); 
                    
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_REF); 
                    is_skip_ref = false; 
                } else {
                    diff_context_t ref_ctx;
                    ref_difftest_exec(1); 
                    ref_difftest_regcpy(&ref_ctx, DIFFTEST_TO_DUT); 
                    checkregs(&ref_ctx); 
                }
            }
#endif
            n--;
        }
    }
}

void sdb_mainloop(){
    char buf[256];
    while(1){
        printf("(npc) ");
        if(fgets(buf, sizeof(buf), stdin) == NULL) break;
        buf[strcspn(buf, "\n")] = 0; 
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
  bool batch_mode = false; 

  for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--batch") == 0) {
          batch_mode = true;
      } else if (img_file == NULL) {
          img_file = argv[i];
      } else if (elf_file == NULL) {
          elf_file = argv[i];
      }
  }

  load_img(img_file);

  init_disasm();
  init_elf(elf_file);
  
  reset(10);
  if (batch_mode) {
      printf("\033[1;36m[NPC] 运行在 Batch 模式 (自动执行)...\033[0m\n");
      cpu_exec(-1); 
  } else {
      printf("\033[1;36m[NPC] 运行在 SDB 模式 (交互调试)...\033[0m\n");
      sdb_mainloop(); 
  }
  
  return 0;
}*/
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <nvboard.h>
#include <VysyxSoCFull.h>
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
extern "C" int npc_is_commit(); 
extern "C" int npc_check_skip();

bool is_skip_ref = false;

static VysyxSoCFull dut;

// =======================================================================
// MROM 定义 (0x2000_0000 ~ 0x2000_0fff)
// =======================================================================
#define MROM_SIZE 0x1000 
uint8_t mrom[MROM_SIZE];
#define MROM_BASE 0x20000000

#define ENABLE_ITRACE 0
#define ENABLE_MTRACE 0
#define ENABLE_FTRACE 0
#define ENABLE_DIFFTEST 1

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

// =======================================================================
// 自动获取正确的 DPI-C 作用域 (智能匹配常见路径)
// =======================================================================
svScope get_dpi_scope() {
    static svScope scope = NULL;
    if (scope == NULL) {
        const char* possible_scopes[] = {
            "TOP.ysyxSoCFull.asic.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.cpu.ysyx_23060000",
            "TOP.ysyxSoCFull.cpu.cpu",
            "TOP.ysyxSoCFull.cpu",
            "TOP.ysyxSoCFull.asic.ysyx_00000000",
            "TOP.ysyxSoCFull.asic.ysyx_23060000",
            "TOP.ysyxSoCFull.ysyx_00000000",
            "TOP.ysyxSoCFull.ysyx_23060000"
        };
        for (int i = 0; i < 10; i++) {
            scope = svGetScopeFromName(possible_scopes[i]);
            if (scope) {
                printf("\033[1;32m[NPC] 成功匹配到 DPI-C 作用域: %s\033[0m\n", possible_scopes[i]);
                break;
            }
        }
        if (!scope) {
            printf("\n\033[1;31m[ERROR] 所有的预设作用域都未找到！\033[0m\n");
            printf("请在终端运行: grep -r \"svGetScopeFromName\" build/obj_dir/ 来查看真实的路径。\n");
            assert(0);
        }
    }
    return scope;
}

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
        printf("ERROR: Capstone init failed: %s\n", cs_strerror(err));
        return;
    }
    capstone_initialized = true;
    printf("Capstone initialized successfully.\n");
}

extern "C" void npc_itrace_commit(uint32_t pc, uint32_t inst, uint32_t dnpc) {
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

    #if ENABLE_FTRACE
    uint32_t opcode = inst & 0x7F;           
    uint32_t rd     = (inst >> 7) & 0x1F;    
    uint32_t rs1    = (inst >> 15) & 0x1F;   

    bool is_jal  = (opcode == 0x6F);         
    bool is_jalr = (opcode == 0x67);         

    if ((is_jal || is_jalr) && (rd == 1)) {
        ftrace_print(pc, dnpc, true);
    }
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
    
    svSetScope(get_dpi_scope());
    
    ref_difftest_init(0);
    // 现在将镜像拷贝到 MROM 基地址，以供 DiffTest 使用
    ref_difftest_memcpy(MROM_BASE, mrom, img_size, DIFFTEST_TO_REF);
    diff_context_t ctx ;
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT); 
    ctx.pc = MROM_BASE;
    for(int i = 0; i < 16; i++) {
        ctx.gpr[i] = npc_read_gpr(i); 
    }
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

void single_cycle() {
  dut.clock = 0;dut.eval();
  dut.clock = 1;dut.eval();
}

void reset(int n) {
  dut.reset = 1;
  while(n-- >0) single_cycle();
  dut.reset = 0;
}

extern "C" void npc_trap(int a0_val) {
    printf("--------------------------------------\n");
    if (a0_val == 0) {
        printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m\n"); 
    } else {
        printf("\033[1;31mNPC: HIT BAD TRAP (Code = %d)\033[0m\n", a0_val); 
    }
    printf("--------------------------------------\n");
    Verilated::gotFinish(true);
}

void load_img(char *img_file) {
    if (img_file == NULL) {
        printf("警告: 未提供 bin 文件路径！将使用默认的内置测试程序。\n");
        // 如果没有提供 bin 文件，我们在 MROM 中放一条跳转到自身的死循环指令
        uint32_t built_in_prog[] = {
            0x0000006f // j pc
        };
        memcpy(mrom, built_in_prog, sizeof(built_in_prog));
        return;
    }
    char *so_file  = "/home/vboxuser/clip/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so";
    FILE *fp = fopen(img_file, "rb");
    assert(fp != NULL); 
    
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (size > MROM_SIZE) {
        printf("ERROR: 镜像文件太大，无法放入 MROM！\n");
        assert(0);
    }
    
    // 【修改点】：将镜像文件读入 mrom 数组
    size_t ret = fread(mrom, size, 1, fp);
    assert(ret == 1);
    fclose(fp);
    init_difftest(so_file, size);

    printf("成功加载镜像: %s, 大小: %ld bytes (已烧录至 MROM)\n", img_file, size);
}

// =======================================================================
// MROM 读写接口
// =======================================================================
extern "C" void mrom_read(int32_t addr, int32_t *data) { 
    uint32_t uaddr = (uint32_t)addr;
    // 检查地址是否在 MROM 范围内
    if (uaddr >= MROM_BASE && uaddr < MROM_BASE + MROM_SIZE) {
        uint32_t offset = uaddr - MROM_BASE;
        *data = *(uint32_t *)(mrom + offset);
    } else {
        printf("\n\033[1;31m[ERROR] 越界读取 MROM 地址: 0x%08x\033[0m\n", uaddr);
        *data = 0;
    }
}

// 这几个函数保持原样，防止后续遇到未定义引用
extern "C" void flash_read(int32_t addr, int32_t *data) { 
    assert(0); 
}

extern "C" int pmem_read(int raddr) {
    is_skip_ref = true;
    return 0; 
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
   is_skip_ref = true;
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
        uint32_t val = pmem_read(addr); // 注意，如果你想看 MROM，这里要改成调用 mrom 数组
        printf("0x%08x: 0x%08x\n", addr, val);
    }
}

void cpu_exec(uint64_t n){
    svSetScope(get_dpi_scope());
    
    while(n > 0){
        if(Verilated::gotFinish()) {
            printf("仿真结束，停止执行。\n");
            break;
        }
        
        single_cycle();

        if (npc_is_commit()) {
#if ENABLE_DIFFTEST
            if(ref_difftest_exec) {
                if (npc_check_skip() || is_skip_ref) {
                    diff_context_t sync_ctx;
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_DUT);
                    for(int i = 0; i < 16; i++) { 
                        sync_ctx.gpr[i] = npc_read_gpr(i);
                    }
                    sync_ctx.pc = npc_read_pc(); 
                    
                    ref_difftest_regcpy(&sync_ctx, DIFFTEST_TO_REF); 
                    is_skip_ref = false; 
                } else {
                    diff_context_t ref_ctx;
                    ref_difftest_exec(1); 
                    ref_difftest_regcpy(&ref_ctx, DIFFTEST_TO_DUT); 
                    checkregs(&ref_ctx); 
                }
            }
#endif
            n--;
        }
    }
}

void sdb_mainloop(){
    char buf[256];
    while(1){
        printf("(npc) ");
        if(fgets(buf, sizeof(buf), stdin) == NULL) break;
        buf[strcspn(buf, "\n")] = 0; 
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
  bool batch_mode = false; 

  for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--batch") == 0) {
          batch_mode = true;
      } else if (img_file == NULL) {
          img_file = argv[i];
      } else if (elf_file == NULL) {
          elf_file = argv[i];
      }
  }

  load_img(img_file);

  init_disasm();
  init_elf(elf_file);
  
  reset(10);
  if (batch_mode) {
      printf("\033[1;36m[NPC] 运行在 Batch 模式 (自动执行)...\033[0m\n");
      cpu_exec(-1); 
  } else {
      printf("\033[1;36m[NPC] 运行在 SDB 模式 (交互调试)...\033[0m\n");
      sdb_mainloop(); 
  }
  
  return 0;
}