# 1. 引入基础的 riscv.mk (它默认是 64 位的 rv64g)
include $(AM_HOME)/scripts/isa/riscv.mk

# 2. 【核心覆盖】强行追加 32 位的参数，彻底覆盖掉 64 位设定！
# (注意这里补上了 ASFLAGS，确保汇编文件 start.S 也是 32 位)
CFLAGS  += -march=rv32e_zicsr -mabi=ilp32e
ASFLAGS += -march=rv32e_zicsr -mabi=ilp32e
LDFLAGS += -melf32lriscv

# 3. 借用 npc 的软核乘除法库
AM_SRCS := riscv/ysyxsoc/start.S \
           riscv/ysyxsoc/trm.c \
           riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c

# 4. 指定专用的 linker.ld
CFLAGS    += -fdata-sections -ffunction-sections
LDFLAGS   += -T $(AM_HOME)/am/src/riscv/ysyxsoc/linker.ld
LDFLAGS   += --gc-sections -e _start

# === 以下是高级魔法 ===

# 5. 支持 main 函数参数注入
MAINARGS_MAX_LEN = 64
MAINARGS_PLACEHOLDER = the_insert-arg_rule_in_Makefile_will_insert_mainargs_here
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) -DMAINARGS_PLACEHOLDER=$(MAINARGS_PLACEHOLDER)

# 6. 生成 .txt 和 .bin 文件 (去掉了会生成巨大空白的 .bss 选项)
image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -S -O binary $(IMAGE).elf $(IMAGE).bin

insert-arg: image
	@python $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin $(MAINARGS_MAX_LEN) $(MAINARGS_PLACEHOLDER) "$(mainargs)"

# 7. 定义自动化 run 规则
run: insert-arg
	@echo "--------------------------------------------------"
	@echo "[ysyxSoC] 正在运行: $(IMAGE_REL).bin"
	@echo "--------------------------------------------------"
	$(MAKE) -C $(NPC_HOME) sim IMG=$(IMAGE).bin