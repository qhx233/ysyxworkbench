TOPNAME ?= example

# 2. 根据 TOPNAME 自动推导约束文件路径
NXDC_FILES = constr/$(TOPNAME).nxdc
INC_PATH ?=

VERILATOR = verilator
VERILATOR_CFLAGS += -MMD --build -cc --trace \
                -O3 --x-assign fast --x-initial fast --noassert

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir

BIN = $(BUILD_DIR)/$(TOPNAME)
BIN_SIM = $(BUILD_DIR)/$(TOPNAME)_sim

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

# --- NVBoard 相关的构建 ---
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

# Verilog 文件依然抓取所有的 (Verilator 会自动分析依赖并丢弃未使用的模块)
VSRCS = $(shell find $(abspath ./vsrc) -name "*.v")

# [关键修改]: 不再无脑抓取所有 cpp，而是精确抓取和 TOPNAME 同名的 cpp 文件
CSRCS = $(abspath ./csrc/$(TOPNAME).cpp)
CSRCS += $(SRC_AUTO_BIND)

include $(NVBOARD_HOME)/scripts/nvboard.mk
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

# --- 纯仿真 (Sim) 相关的构建 ---
# [关键修改]: 精确抓取 sim 目录下和 TOPNAME 同名的 cpp 文件
CSRCS_SIM = $(abspath ./csrc/sim/$(TOPNAME).cpp)
CXXFLAGS_SIM += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

$(BIN_SIM): $(VSRCS) $(CSRCS_SIM)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS_SIM)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN_SIM))

# --- 执行目标 ---
all: default

run: $(BIN)
	@$^

sim: $(BIN_SIM)
	@$^

clean:
	rm -rf $(BUILD_DIR)

lint: $(VSRCS)
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME $^

.PHONY: default all clean run sim lint