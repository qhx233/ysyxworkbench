TOPNAME = ysyxSoCFull
NXDC_FILES = constr/$(TOPNAME).nxdc
INC_PATH ?=

YSYXSOC_HOME = /home/vboxuser/clip/ysyx-workbench/ysyxSoC

VERILATOR = verilator
# 加入了 --trace，保证仿真时能生成波形
VERILATOR_CFLAGS += -MMD --build -cc --trace \
                -O3 --x-assign fast --x-initial fast --noassert \
                --timescale "1ns/1ns" --no-timing --autoflush \
                -Wno-UNOPTFLAT
VERILATOR_CFLAGS += -I$(YSYXSOC_HOME)/perip/uart16550/rtl
VERILATOR_CFLAGS += -I$(YSYXSOC_HOME)/perip/spi/rtl
ifeq ($(PS2_DEBUG),1)
VERILATOR_CFLAGS += -DPS2_DEBUG
endif
ifeq ($(VGA_DEBUG),1)
VERILATOR_CFLAGS += -DVGA_DEBUG
endif
ifeq ($(SDRAM_DEBUG),1)
VERILATOR_CFLAGS += -DSDRAM_DEBUG
endif

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir

# 定义两个不同的输出文件
BIN = $(BUILD_DIR)/$(TOPNAME)
BIN_SIM = $(BUILD_DIR)/$(TOPNAME)_sim

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

# --- NVBoard 相关的构建 ---
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

# [核心修改 2]：将你的 CPU、外设，以及最重要的 ysyxSoCFull.v 合并！
# 1. 找你自己的 CPU 代码
VSRCS_CPU = $(shell find $(abspath ./vsrc) -name "*.v")
# 2. 找 ysyxSoC 官方提供的所有外设代码 (UART, SPI, Flash, PS2键盘等)
VSRCS_PERIP = $(shell find $(YSYXSOC_HOME)/perip -name "*.v")
# 3. 强行加入 ysyxSoCFull 的顶层文件 ！！！
YSYXSOC_FULL_V = $(YSYXSOC_HOME)/build/ysyxSoCFull.v
# 4. 将它们拼在一起喂给 Verilator
VSRCS = $(VSRCS_CPU) $(VSRCS_PERIP) $(YSYXSOC_FULL_V)

CSRCS = $(shell find $(abspath ./csrc) -maxdepth 1 -name "*.c" -or -name "*.cc" -or -name "*.cpp")
CSRCS += $(SRC_AUTO_BIND)

include $(NVBOARD_HOME)/scripts/nvboard.mk
LDFLAGS += -lcapstone  -lelf -ldl
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

$(BIN): CXXFLAGS += -DENABLE_NVBOARD
$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		-LDFLAGS -L/usr/lib \
		-LDFLAGS -lcapstone \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

# --- 纯仿真 (Sim) 相关的构建 ---
# [核心修复 3]：直接写死主函数路径，不再去不存在的 sim 目录找了！
CSRCS_SIM = $(abspath ./csrc/main.cpp)
CXXFLAGS_SIM += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

# 把源文件编译成纯仿真程序 $(BIN_SIM) 的规则
$(BIN_SIM): $(VSRCS) $(CSRCS_SIM)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS_SIM)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN_SIM))

# --- 执行目标 ---
all: default


IMG ?=
ARGS ?= --flash-boot

run: $(BIN)
	@$^ $(ARGS) $(IMG)

# 增加 IMG/ARGS 变量，允许从命令行传参；默认从 FLASH 取指，ARGS= 可保留 MROM 路径。

sim: $(BIN_SIM)
	@$^ $(ARGS) $(IMG)


clean:
	rm -rf $(BUILD_DIR)

# --- 代码检查 (Lint) ---
lint: $(VSRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME $^

.PHONY: default all clean run sim lint
