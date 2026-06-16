#include <stdio.h>
#include <nvboard.h>
#include <Valu.h> // Verilator 根据 alu.v 自动生成的头文件

// 实例化 alu 模块
static Valu dut;

// 声明引脚绑定函数，类型也必须改成 Valu*
void nvboard_bind_all_pins(Valu* top);

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