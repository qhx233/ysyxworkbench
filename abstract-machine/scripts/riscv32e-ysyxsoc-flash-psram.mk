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

CFLAGS  += -Os -D__YSYXSOC_LOAD_TO_PSRAM__
ASFLAGS += -D__YSYXSOC_LOAD_TO_PSRAM__
CFLAGS  += -fdata-sections -ffunction-sections
ifneq ($(MEM_TEST_LIMIT),)
CFLAGS  += -DMEM_TEST_LIMIT=$(MEM_TEST_LIMIT)
endif
LDFLAGS += -T $(AM_HOME)/am/src/riscv/ysyxsoc/linker-flash-psram.ld
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
	@echo "[ysyxSoC flash->psram] 正在运行: $(IMAGE_REL).bin"
	@echo "--------------------------------------------------"
ifeq ($(NO_DIFFTEST),1)
	$(MAKE) -C $(NPC_HOME) sim IMG=$(IMAGE).bin ARGS="--flash-boot --no-difftest -b"
else
	$(MAKE) -C $(NPC_HOME) sim IMG=$(IMAGE).bin ARGS="--flash-boot -b"
endif
