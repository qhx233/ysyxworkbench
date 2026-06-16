#include <stdio.h>
#include <nvboard.h>
#include <Vkeyboard.h> // 根据你的模块名生成的头文件

static Vkeyboard dut;

void nvboard_bind_all_pins(Vkeyboard* top);

// 模拟系统时钟
static void single_cycle() {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

// 模拟上电复位
static void reset(int n) {
    dut.rst = 1;
    while(n-- > 0) single_cycle();
    dut.rst = 0;
}

int main() {
    nvboard_bind_all_pins(&dut);
    nvboard_init();
    
    // 初始化复位
    reset(10); 

    while (1) {
        nvboard_update();
        // 持续提供高速的系统时钟，用于采样 PS/2 慢速时钟
        single_cycle();   
    }

    nvboard_quit();
    return 0;
}