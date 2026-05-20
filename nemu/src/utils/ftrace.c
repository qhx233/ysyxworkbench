#include <common.h>
#include <elf.h>
#include <assert.h>

extern char *elf_file;

#define MAX_SYMB 128

typedef struct {
  char name[64];
  paddr_t addr;
  uint32_t size;
} SymbolEntry;

static SymbolEntry symbol_table[MAX_SYMB] __attribute__((unused));
static int symbol_cnt __attribute__((unused)) = 0;


void init_ftrace(){
    if(elf_file == NULL) {
        Log("No ELF file provided, skipping ftrace initialization.");
        return;
    }

    FILE *fp = fopen(elf_file, "rb");
    Assert(fp, "Can not open '%s'",elf_file);

    Elf32_Ehdr ehdr;
    int ret = fread(&ehdr, sizeof(ehdr), 1, fp);
    Assert(ret == 1, "Failed to read ELF header from '%s'", elf_file);

    if (*(uint32_t *)ehdr.e_ident != 0x464c457f) { // 0x7f E L F 的小端序
        panic("Not a valid ELF file!");
    }

    Log("ELF file loaded. Section header offset: 0x%x, Section header count: %d", 
        ehdr.e_shoff, ehdr.e_shnum);

    fseek(fp, ehdr.e_shoff, SEEK_SET);
    Elf32_Shdr *shdr = malloc(ehdr.e_shnum * sizeof(Elf32_Shdr));
    Assert(shdr, "Failed to allocate memory for section headers");
    ret = fread(shdr, sizeof(Elf32_Shdr), ehdr.e_shnum, fp);
    Assert(ret == ehdr.e_shnum, "Failed to read section headers from '%s'", elf_file);

    Elf32_Shdr *symtab_shdr = NULL;
    Elf32_Shdr *strtab_shdr = NULL;

    for (int i = 0; i < ehdr.e_shnum; i++) {
        if (shdr[i].sh_type == SHT_SYMTAB) {
            symtab_shdr = &shdr[i];
            strtab_shdr = &shdr[symtab_shdr->sh_link];
            break;
        }
    }

    Assert(symtab_shdr && strtab_shdr, "Failed to find symbol table in ELF file '%s'", elf_file);

    Log("Symbol table offset: 0x%x, size: %d bytes", symtab_shdr->sh_offset, symtab_shdr->sh_size);
    Log("String table offset: 0x%x, size: %d bytes", strtab_shdr->sh_offset, strtab_shdr->sh_size);

    char *strtab = malloc(strtab_shdr->sh_size);
    Assert(strtab, "Failed to allocate memory for string table");
    fseek(fp, strtab_shdr->sh_offset, SEEK_SET);
    ret = fread(strtab, strtab_shdr->sh_size, 1, fp);
    Assert(ret == 1, "Failed to read string table");

    // 2. 读取符号表 (通讯录)
    Elf32_Sym *symtab = malloc(symtab_shdr->sh_size);
    Assert(symtab, "Failed to allocate memory for symbol table");
    fseek(fp, symtab_shdr->sh_offset, SEEK_SET);
    ret = fread(symtab, symtab_shdr->sh_size, 1, fp);
    Assert(ret == 1, "Failed to read symbol table");

    // 3. 计算符号表里一共有多少个符号
    // 符号表的大小 / 单个符号结构体的大小 = 符号的数量
    int sym_num = symtab_shdr->sh_size / sizeof(Elf32_Sym);

    // 4. 遍历所有符号，提取出“函数”
    for (int i = 0; i < sym_num; i++) {
        // ELF32_ST_TYPE 是一个宏，用来从 st_info 字段中提取符号的类型
        // STT_FUNC 代表这个符号是一个函数 (Function)
        if (ELF32_ST_TYPE(symtab[i].st_info) == STT_FUNC) {
            
            // 防止我们的数组越界
            if (symbol_cnt >= MAX_SYMB) {
                Log("Warning: Too many symbols. Some symbols are ignored.");
                break;
            }

            // symtab[i].st_name 存放的是该名字在字符串表 (strtab) 中的偏移量
            // 我们通过 strtab + symtab[i].st_name 就能拿到真正的字符串指针
            strncpy(symbol_table[symbol_cnt].name, strtab + symtab[i].st_name, sizeof(symbol_table[0].name) - 1);
            symbol_table[symbol_cnt].addr = symtab[i].st_value;
            symbol_table[symbol_cnt].size = symtab[i].st_size;
            
            // 打印出来看看我们抓到了什么
            /*Log("Found Func: %s, Addr: 0x%x, Size: %d", 
                symbol_table[symbol_cnt].name, 
                symbol_table[symbol_cnt].addr, 
                symbol_table[symbol_cnt].size);*/

            symbol_cnt++;
        }
    }
    Log("ftrace initialization complete. Loaded %d functions.", symbol_cnt);

    // 打扫战场：释放所有的动态内存
    free(symtab);
    free(strtab);


    free(shdr);
    fclose(fp);
}

static int call_depth = 0;

void print_ftrace(paddr_t pc, paddr_t dnpc, int is_call) {
    if (symbol_cnt == 0) return; // 如果没加载 ELF，直接跳过

    // 1. 拿着 dnpc (目标地址) 去 symbol_table 里找，看看落在哪一个函数的区间内
    char *func_name = "???";
    for (int i = 0; i < symbol_cnt; i++) {
        if (dnpc >= symbol_table[i].addr && dnpc < (symbol_table[i].addr + symbol_table[i].size)) {
            func_name = symbol_table[i].name;
            break;
        }
    }

    // 2. 根据是 call 还是 ret，调整缩进并打印
    if (is_call) {
        Log(FMT_PADDR ": %*scall [%s@" FMT_PADDR "]", pc, call_depth * 2, "", func_name, dnpc);
        call_depth++;
    } else {
        call_depth--;
        if (call_depth < 0) call_depth = 0; // 防止深度变为负数
        Log(FMT_PADDR ": %*sret  [%s]", pc, call_depth * 2, "", func_name);
    }
}