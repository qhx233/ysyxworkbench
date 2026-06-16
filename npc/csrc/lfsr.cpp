#include <stdio.h>
#include <nvboard.h>
#include <Vlfsr.h> // 注意头文件名字

static Vlfsr dut;

void nvboard_bind_all_pins(Vlfsr* top);

// 模拟一次时钟脉冲
static void single_cycle() {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

// 模拟系统上电时的初始复位
static void reset(int n) {
    dut.rst = 1;
    while(n-- > 0) single_cycle();
    dut.rst = 0;
}

int main() {
    nvboard_bind_all_pins(&dut);
    nvboard_init();
    
    // 给系统 10 个周期的复位信号，使其初始化为 00000001
    reset(10); 

    while (1) {
        nvboard_update();
        // 不断提供系统时钟脉冲
        single_cycle();   
    }

    nvboard_quit();
    return 0;
}