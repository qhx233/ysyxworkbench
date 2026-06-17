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
#include <errno.h>
#include <vector>
#include <dlfcn.h>

extern "C" int npc_read_gpr(int idx);
extern "C" uint32_t npc_read_pc();
extern "C" int npc_is_commit(); 
extern "C" int npc_check_skip();

bool is_skip_ref = false;

static VysyxSoCFull dut;

#ifdef ENABLE_NVBOARD
void nvboard_bind_all_pins(VysyxSoCFull* top);
#endif

static const int UART_BIT_TICKS = 16;
static bool uart_stdin_enabled = false;
static bool uart_stdin_inited = false;
static uint16_t uart_rx_frame = 0x3ff;
static int uart_rx_bits = 0;
static int uart_rx_ticks = 0;

static int uart_tx_state = 0;
static int uart_tx_ticks = 0;
static int uart_tx_bits = 0;
static uint8_t uart_tx_data = 0;
static bool uart_debug_enabled = false;

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

static void sample_uart_tx() {
  int tx = dut.externalPins_uart_tx ? 1 : 0;

  if (uart_tx_state == 0) {
    if (tx == 0) {
      uart_tx_state = 1;
      uart_tx_ticks = UART_BIT_TICKS + UART_BIT_TICKS / 2;
      uart_tx_bits = 0;
      uart_tx_data = 0;
    }
    return;
  }

  if (--uart_tx_ticks > 0) return;

  if (uart_tx_state == 1) {
    if (uart_tx_bits < 8) {
      uart_tx_data |= (uint8_t)(tx << uart_tx_bits);
      uart_tx_bits++;
      uart_tx_ticks = UART_BIT_TICKS;
    } else {
      putchar(uart_tx_data);
      fflush(stdout);
      uart_tx_state = 0;
    }
  }
}

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
            "ysyxSoCFull.asic.cpu.cpu.cpu",
            "ysyxSoCFull.asic.cpu.cpu.ysyx_23060000",
            "ysyxSoCFull.asic.cpu.cpu",
            "ysyxSoCFull.asic.cpu",
            "ysyxSoCFull.asic.cpu.ysyx_00000000",
            "ysyxSoCFull.asic.cpu.ysyx_23060000",
            "TOP.ysyxSoCFull.asic.cpu.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu.cpu.ysyx_23060000",
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
    if (pc_trace_fp != NULL) {
        fprintf(pc_trace_fp, "0x%08x\n", pc);
    }

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
  drive_uart_rx();
  dut.clock = 0;dut.eval();
  dut.clock = 1;dut.eval();
  sample_uart_tx();
#ifdef ENABLE_NVBOARD
  nvboard_update();
#endif
}

void reset(int n) {
  dut.reset = 1;
  uart_stdin_enabled = false;
  while(n-- >0) single_cycle();
  dut.reset = 0;
  uart_stdin_enabled = true;
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
        svSetScope(get_dpi_scope());
        printf("\n\033[1;31m[ERROR] 越界读取 MROM 地址: 0x%08x, CPU PC: 0x%08x\033[0m\n", uaddr, npc_read_pc());
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
  uart_debug_enabled = getenv("NPC_UART_DEBUG") != NULL;
  const char *pc_trace_path = getenv("NPC_PC_TRACE");
  
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
#include <errno.h>
#include <vector>
#include <dlfcn.h>

static FILE *pc_trace_fp = NULL;

extern "C" int npc_read_gpr(int idx);
extern "C" uint32_t npc_read_pc();
extern "C" int npc_is_commit(); 
extern "C" int npc_check_skip();

bool is_skip_ref = false;

static VysyxSoCFull dut;

#ifdef ENABLE_NVBOARD
void nvboard_bind_all_pins(VysyxSoCFull* top);
#endif

static const int UART_BIT_TICKS = 16;
static bool uart_stdin_enabled = false;
static bool uart_stdin_inited = false;
static uint16_t uart_rx_frame = 0x3ff;
static int uart_rx_bits = 0;
static int uart_rx_ticks = 0;
static bool uart_debug_enabled = false;

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
uint8_t mrom[MROM_SIZE];
#define MROM_BASE 0x20000000
#define SRAM_BASE 0x0f000000
#define SRAM_SIZE 0x2000
#define FLASH_BASE 0x30000000
#define FLASH_SIZE 0x1000000
uint8_t sram[SRAM_SIZE];
uint8_t flash[FLASH_SIZE];
static long img_size_loaded = 0;
static bool flash_boot = false;
static const char *ref_so_file = "/home/vboxuser/clip/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so";

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

extern "C" int npc_reset_pc() {
    return flash_boot ? FLASH_BASE : MROM_BASE;
}

// =======================================================================
// 自动获取正确的 DPI-C 作用域 (智能匹配常见路径)
// =======================================================================
svScope get_dpi_scope() {
    static svScope scope = NULL;
    if (scope == NULL) {
        const char* possible_scopes[] = {
            "ysyxSoCFull.asic.cpu.cpu.cpu",
            "ysyxSoCFull.asic.cpu.cpu.ysyx_23060000",
            "ysyxSoCFull.asic.cpu.cpu",
            "ysyxSoCFull.asic.cpu",
            "ysyxSoCFull.asic.cpu.ysyx_00000000",
            "ysyxSoCFull.asic.cpu.ysyx_23060000",
            "TOP.ysyxSoCFull.asic.cpu.cpu.cpu",
            "TOP.ysyxSoCFull.asic.cpu.cpu.ysyx_23060000",
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
    if (pc_trace_fp != NULL) {
        fprintf(pc_trace_fp, "0x%08x\n", pc);
    }
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
    memset(sram, 0, sizeof(sram));
    ref_difftest_memcpy(MROM_BASE, mrom, MROM_SIZE, DIFFTEST_TO_REF);
    ref_difftest_memcpy(SRAM_BASE, sram, sizeof(sram), DIFFTEST_TO_REF);
    if (flash_boot) {
        ref_difftest_memcpy(FLASH_BASE, flash, img_size, DIFFTEST_TO_REF);
    }

    diff_context_t ctx ;
    ref_difftest_regcpy(&ctx, DIFFTEST_TO_DUT); 
    ctx.pc = npc_read_pc();
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
static uint64_t perf_cycles = 0;
static uint64_t perf_insts = 0;

enum {
  PERF_CAT_ALU = 0,
  PERF_CAT_LOAD,
  PERF_CAT_STORE,
  PERF_CAT_BRANCH,
  PERF_CAT_JUMP,
  PERF_CAT_CSR,
  PERF_CAT_SYSTEM,
  PERF_CAT_OTHER,
  PERF_CAT_NR
};

enum {
  PERF_EVT_IFU_FETCH = 0,
  PERF_EVT_LSU_LOAD_DATA = 1,
  PERF_EVT_LSU_STORE_DONE = 2,
  PERF_EVT_EXU_DONE = 3,
  PERF_EVT_ICACHE_HIT = 4,
  PERF_EVT_ICACHE_MISS = 5,
  PERF_EVT_IFU_WAIT_REQ = 10,
  PERF_EVT_IFU_WAIT_RSP = 11,
  PERF_EVT_IFU_WAIT_LSU_LD = 12,
  PERF_EVT_IFU_WAIT_LSU_ST = 13,
  PERF_EVT_LSU_LOAD_LAT = 20,
  PERF_EVT_LSU_STORE_LAT = 21,
  PERF_EVT_ICACHE_MISS_LAT = 22
};

static const char *perf_cat_name[PERF_CAT_NR] = {
  "ALU", "LOAD", "STORE", "BRANCH", "JUMP", "CSR", "SYSTEM", "OTHER"
};

static uint64_t perf_cat_count[PERF_CAT_NR];
static uint64_t perf_cat_cycles[PERF_CAT_NR];
static uint64_t perf_ifu_fetch = 0;
static uint64_t perf_lsu_load_data = 0;
static uint64_t perf_lsu_store_done = 0;
static uint64_t perf_exu_done = 0;
static uint64_t perf_icache_hit = 0;
static uint64_t perf_icache_miss = 0;
static uint64_t perf_ifu_wait_req = 0;
static uint64_t perf_ifu_wait_rsp = 0;
static uint64_t perf_ifu_wait_lsu_ld = 0;
static uint64_t perf_ifu_wait_lsu_st = 0;
static uint64_t perf_lsu_load_lat_sum = 0;
static uint64_t perf_lsu_store_lat_sum = 0;
static uint64_t perf_lsu_load_lat_count = 0;
static uint64_t perf_lsu_store_lat_count = 0;
static uint64_t perf_icache_miss_lat_sum = 0;
static uint64_t perf_icache_miss_lat_count = 0;

static uint64_t get_time_internal(){
    struct timeval now;
    gettimeofday(&now, NULL);
    return now.tv_sec * 1000000ull + now.tv_usec;
}

static void reset_perf_stats() {
  perf_cycles = 0;
  perf_insts = 0;
  memset(perf_cat_count, 0, sizeof(perf_cat_count));
  memset(perf_cat_cycles, 0, sizeof(perf_cat_cycles));
  perf_ifu_fetch = 0;
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
  boot_time = get_time_internal();
}

extern "C" void npc_perf_event(int event, int data) {
  switch (event) {
    case PERF_EVT_IFU_FETCH:       perf_ifu_fetch++; break;
    case PERF_EVT_LSU_LOAD_DATA:   perf_lsu_load_data++; break;
    case PERF_EVT_LSU_STORE_DONE:  perf_lsu_store_done++; break;
    case PERF_EVT_EXU_DONE:        perf_exu_done++; break;
    case PERF_EVT_ICACHE_HIT:      perf_icache_hit++; break;
    case PERF_EVT_ICACHE_MISS:     perf_icache_miss++; break;
    case PERF_EVT_IFU_WAIT_REQ:    perf_ifu_wait_req++; break;
    case PERF_EVT_IFU_WAIT_RSP:    perf_ifu_wait_rsp++; break;
    case PERF_EVT_IFU_WAIT_LSU_LD: perf_ifu_wait_lsu_ld++; break;
    case PERF_EVT_IFU_WAIT_LSU_ST: perf_ifu_wait_lsu_st++; break;
    case PERF_EVT_LSU_LOAD_LAT:
      perf_lsu_load_lat_sum += (uint32_t)data;
      perf_lsu_load_lat_count++;
      break;
    case PERF_EVT_LSU_STORE_LAT:
      perf_lsu_store_lat_sum += (uint32_t)data;
      perf_lsu_store_lat_count++;
      break;
    case PERF_EVT_ICACHE_MISS_LAT:
      perf_icache_miss_lat_sum += (uint32_t)data;
      perf_icache_miss_lat_count++;
      break;
    default:
      break;
  }
}

extern "C" void npc_perf_commit(int category, int cycles) {
  if (category < 0 || category >= PERF_CAT_NR) {
    category = PERF_CAT_OTHER;
  }
  perf_cat_count[category]++;
  perf_cat_cycles[category] += (uint32_t)cycles;
}

static void print_perf_stats() {
  uint64_t elapsed_us = get_time_internal() - boot_time;
  double ipc = perf_cycles == 0 ? 0.0 : (double)perf_insts / (double)perf_cycles;
  double cpi = perf_insts == 0 ? 0.0 : (double)perf_cycles / (double)perf_insts;
  double sim_freq = elapsed_us == 0 ? 0.0 : (double)perf_cycles / (double)elapsed_us;
  uint64_t decoded_insts = 0;
  uint64_t ifu_wait_total = perf_ifu_wait_req + perf_ifu_wait_rsp + perf_ifu_wait_lsu_ld + perf_ifu_wait_lsu_st;
  uint64_t icache_access = perf_icache_hit + perf_icache_miss;
  double icache_miss_rate = icache_access == 0 ? 0.0 : (double)perf_icache_miss / (double)icache_access;
  double icache_access_time = 1.0;
  double icache_avg_miss_penalty =
    perf_icache_miss_lat_count == 0 ? 0.0 : (double)perf_icache_miss_lat_sum / (double)perf_icache_miss_lat_count;
  double icache_amat = icache_access_time + icache_miss_rate * icache_avg_miss_penalty;

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
  drive_uart_rx();
  dut.clock = 0;dut.eval();
  dut.clock = 1;dut.eval();
  perf_cycles++;
#ifdef ENABLE_NVBOARD
  nvboard_update();
#endif
}

void reset(int n) {
  dut.reset = 1;
  uart_stdin_enabled = false;
  while(n-- >0) single_cycle();
  dut.reset = 0;
  uart_stdin_enabled = true;
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
        uint32_t built_in_prog[] = {
            0x0000006f // j pc
        };
        if (flash_boot) {
            memcpy(flash, built_in_prog, sizeof(built_in_prog));
        } else {
            memcpy(mrom, built_in_prog, sizeof(built_in_prog));
        }
        img_size_loaded = sizeof(built_in_prog);
        return;
    }
    FILE *fp = fopen(img_file, "rb");
    assert(fp != NULL); 
    
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    long capacity = flash_boot ? FLASH_SIZE : MROM_SIZE;
    if (size > capacity) {
        printf("ERROR: 镜像文件太大，无法放入 %s！\n", flash_boot ? "FLASH" : "MROM");
        assert(0);
    }
    
    uint8_t *dest = flash_boot ? flash : mrom;
    size_t ret = fread(dest, size, 1, fp);
    assert(ret == 1);
    fclose(fp);
    img_size_loaded = size;

    printf("成功加载镜像: %s, 大小: %ld bytes (已烧录至 %s)\n", img_file, size, flash_boot ? "FLASH" : "MROM");
}

static uint32_t flash_pattern(uint32_t addr) {
    uint32_t word_addr = addr & ~0x3u;
    return 0x5a000000u ^ (word_addr * 0x01010101u) ^ (word_addr << 8);
}

void init_flash() {
    memset(flash, 0xff, sizeof(flash));
    for (uint32_t addr = 0; addr < 0x1000; addr += sizeof(uint32_t)) {
        uint32_t data = flash_pattern(addr);
        memcpy(flash + addr, &data, sizeof(data));
    }
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
        svSetScope(get_dpi_scope());
        printf("\n\033[1;31m[ERROR] 越界读取 MROM 地址: 0x%08x, CPU PC: 0x%08x\033[0m\n", uaddr, npc_read_pc());
        *data = 0;
    }
}

// 这几个函数保持原样，防止后续遇到未定义引用
extern "C" void flash_read(int32_t addr, int32_t *data) { 
    uint32_t uaddr = (uint32_t)addr;
    if (uaddr + sizeof(uint32_t) <= FLASH_SIZE) {
        memcpy(data, flash + uaddr, sizeof(uint32_t));
    } else {
        printf("\n\033[1;31m[ERROR] 越界读取 FLASH 地址: 0x%08x\033[0m\n", FLASH_BASE + uaddr);
        *data = 0;
    }
}

extern "C" int pmem_read(int raddr) {
    uint32_t uaddr = (uint32_t)raddr;
    if (uaddr >= SRAM_BASE && uaddr + sizeof(uint32_t) <= SRAM_BASE + SRAM_SIZE) {
        return *(uint32_t *)(sram + uaddr - SRAM_BASE);
    }
    is_skip_ref = true;
    return 0;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
    uint32_t uaddr = (uint32_t)waddr;
    if (uaddr >= SRAM_BASE && uaddr + sizeof(uint32_t) <= SRAM_BASE + SRAM_SIZE) {
        uint32_t offset = uaddr - SRAM_BASE;
        for (int i = 0; i < 4; i++) {
            if ((wmask >> i) & 0x1) {
                sram[offset + i] = (wdata >> (i * 8)) & 0xff;
            }
        }
        return;
    }
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
        uint32_t val = 0;
        if (addr >= MROM_BASE && addr + sizeof(uint32_t) <= MROM_BASE + MROM_SIZE) {
            val = *(uint32_t *)(mrom + addr - MROM_BASE);
        } else {
            val = pmem_read(addr);
        }
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
            perf_insts++;
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
  uart_debug_enabled = getenv("NPC_UART_DEBUG") != NULL;
  const char *pc_trace_path = getenv("NPC_PC_TRACE");
  
  boot_time = get_time_internal();

  char *img_file = NULL;
  char *elf_file = NULL;
  bool batch_mode = false; 

  for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--batch") == 0) {
          batch_mode = true;
      } else if (strcmp(argv[i], "--flash-boot") == 0) {
          flash_boot = true;
      } else if (strcmp(argv[i], "--no-difftest") == 0) {
          ref_so_file = NULL;
      } else if (strcmp(argv[i], "--pc-trace") == 0 && i + 1 < argc) {
          pc_trace_path = argv[++i];
      } else if (img_file == NULL) {
          img_file = argv[i];
      } else if (elf_file == NULL) {
          elf_file = argv[i];
      }
  }

  if (pc_trace_path != NULL && pc_trace_path[0] != '\0') {
      pc_trace_fp = fopen(pc_trace_path, "w");
      if (pc_trace_fp == NULL) {
          perror("open pc trace");
          assert(0);
      }
      printf("[NPC] PC trace will be written to %s\n", pc_trace_path);
  }

  init_flash();
  load_img(img_file);

  init_disasm();
  init_elf(elf_file);

#ifdef ENABLE_NVBOARD
  nvboard_bind_all_pins(&dut);
  nvboard_init();
#endif
  
  reset(10);
  reset_perf_stats();
  init_difftest(ref_so_file, img_size_loaded);
  if (batch_mode) {
      printf("\033[1;36m[NPC] 运行在 Batch 模式 (自动执行)...\033[0m\n");
      cpu_exec(-1); 
  } else {
      printf("\033[1;36m[NPC] 运行在 SDB 模式 (交互调试)...\033[0m\n");
      sdb_mainloop(); 
  }

  print_perf_stats();

  if (pc_trace_fp != NULL) {
      fclose(pc_trace_fp);
      pc_trace_fp = NULL;
  }

#ifdef ENABLE_NVBOARD
  nvboard_quit();
#endif
  
  return 0;
}
