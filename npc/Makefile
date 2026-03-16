TOPNAME = example
NXDC_FILES = constr/example.nxdc
INC_PATH ?=

VERILATOR = verilator
# 加入了 --trace，保证仿真时能生成波形
VERILATOR_CFLAGS += -MMD --build -cc --trace \
                -O3 --x-assign fast --x-initial fast --noassert

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

# 修复冲突：加上 -maxdepth 1，只在 csrc 第一层找，不进入 sim/ 文件夹
VSRCS = $(shell find $(abspath ./vsrc) -name "*.v")
CSRCS = $(shell find $(abspath ./csrc) -maxdepth 1 -name "*.c" -or -name "*.cc" -or -name "*.cpp")
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
# 这里去 csrc/sim/ 目录下找仿真用的 main 函数
CSRCS_SIM = $(shell find $(abspath ./csrc/sim) -name "*.c" -or -name "*.cc" -or -name "*.cpp")
CXXFLAGS_SIM += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""

# 新增：把源文件编译成纯仿真程序 $(BIN_SIM) 的规则
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

.PHONY: default all clean run sim