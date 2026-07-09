include $(AM_HOME)/scripts/isa/riscv.mk

CFLAGS  += -march=rv32e_zicsr -mabi=ilp32e
ASFLAGS += -march=rv32e_zicsr -mabi=ilp32e
LDFLAGS += -melf32lriscv

AM_SRCS := riscv/ysyxsoc/start.S \
           riscv/ysyxsoc/trm.c \
           riscv/npc/trap.S \
           riscv/npc/cte.c \
           riscv/ysyxsoc/ioe.c \
           riscv/ysyxsoc/timer.c \
           riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c

CFLAGS  += -Os -D__YSYXSOC_LOAD_TO_SDRAM__
ASFLAGS += -D__YSYXSOC_LOAD_TO_SDRAM__
CFLAGS  += -fdata-sections -ffunction-sections
ifneq ($(MEM_TEST_LIMIT),)
CFLAGS  += -DMEM_TEST_LIMIT=$(MEM_TEST_LIMIT)
endif
ifneq ($(MEM_TEST_EXTRA_BASE),)
CFLAGS  += -DMEM_TEST_EXTRA_BASE=$(MEM_TEST_EXTRA_BASE)
endif
ifneq ($(MEM_TEST_EXTRA_SIZE),)
CFLAGS  += -DMEM_TEST_EXTRA_SIZE=$(MEM_TEST_EXTRA_SIZE)
endif
ifneq ($(MEM_TEST_EXTRA_WORD_ONLY),)
CFLAGS  += -DMEM_TEST_EXTRA_WORD_ONLY=$(MEM_TEST_EXTRA_WORD_ONLY)
endif
ifeq ($(NVBOARD),1)
CFLAGS  += -DGPIO_HOLD_DISPLAY
endif
LDFLAGS += -T $(AM_HOME)/am/src/riscv/ysyxsoc/linker-flash-sdram.ld
LDFLAGS += --gc-sections -e _start

MAINARGS_MAX_LEN = 64
MAINARGS_PLACEHOLDER = the_insert-arg_rule_in_Makefile_will_insert_mainargs_here
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) -DMAINARGS_PLACEHOLDER=$(MAINARGS_PLACEHOLDER)

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -S -O binary $(IMAGE).elf $(IMAGE).bin

insert-arg: image
	@python $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin $(MAINARGS_MAX_LEN) $(MAINARGS_PLACEHOLDER) "$(mainargs)"

run: insert-arg
	@echo "--------------------------------------------------"
	@echo "[ysyxSoC flash->sdram] 正在运行: $(IMAGE_REL).bin"
	@echo "--------------------------------------------------"
ifeq ($(NVBOARD),1)
	$(MAKE) -C $(NPC_HOME) run IMG="$(IMAGE).bin $(IMAGE).elf" ARGS="--flash-boot --no-difftest -b"
else
	NPC_UART_STDIN=1 $(MAKE) -C $(NPC_HOME) sim IMG="$(IMAGE).bin $(IMAGE).elf" ARGS="--flash-boot --no-difftest -b"
endif
