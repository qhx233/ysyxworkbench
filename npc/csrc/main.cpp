/*#include <stdio.h>
#include <nvboard.h>
#include <Vexample.h>

static Vexample dut;

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


int main() {
  nvboard_bind_all_pins(&dut);
  nvboard_init();
  reset(10);
  while(1) {
    nvboard_update();
    single_cycle();
  }
  nvboard_quit();
  return 0;
}*/
//////111111////////////////////
////////////22222//////////////////
/*
#include <stdio.h>
#include <nvboard.h>
#include <Vexample.h>  // 引入 example 模块的头文件

static Vexample dut;   // 实例化 example 模块

void nvboard_bind_all_pins(Vexample* top);

int main() {
  // 1. 绑定引脚
  nvboard_bind_all_pins(&dut);
  
  // 2. 初始化 NVBoard
  nvboard_init();
  
  // 3. 主循环（纯组合逻辑，不需要时钟 clk 和复位 rst）
  while(1) {
    // 读取 NVBoard 上拨码开关的输入状态
    nvboard_update(); 
    
    // 直接计算组合逻辑的输出结果，不需要驱动 clk 翻转
    dut.eval();       
  }
  
  // 4. 退出清理
  nvboard_quit();
  return 0;
}*/
#include <stdio.h>
#include <nvboard.h>
#include <Vexample.h> // Verilator 根据 example.v 自动生成的头文件

// 实例化 example 模块
static Vexample dut;

// 声明引脚绑定函数
void nvboard_bind_all_pins(Vexample* top);

int main() {
    // 1. 将 NVBoard 的虚拟引脚绑定到你的 Verilog 模块上
    nvboard_bind_all_pins(&dut);
    
    // 2. 初始化 NVBoard 界面
    nvboard_init();

    // 3. 组合逻辑主循环 (无需时钟 clk)
    while (1) {
        // 读取 NVBoard 上拨码开关的状态
        nvboard_update(); 
        
        // 让 Verilator 对电路进行一次求值，更新输出信号到 LED
        dut.eval();       
    }

    // 4. 退出清理
    nvboard_quit();
    return 0;
}
