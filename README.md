# Triathlon

## 一、项目介绍

**项目主要目录**:
``` shell
Triathlon
├── abstract-machine                 # 裸机运行时环境(目前忽略它)
├── am-kernels                       # 测试处理器的软件程序
│    ├── benchmarks                  # benchmark测试程序
│    └── cpu-tests                   # 简单cpu测试程序
├── nemu                             # 模拟器 
├── npc                              # 测试框架
│    ├── include                     # 相关.h文件  
│    │   csrc                        # 用于测试的环境
│    │   vsrc                        # 测试的core
│    └── Makefile                    
├── Makefile                         
└── README.md
```

## 二、实验环境搭建(以Ubuntu22.04为例)

### 工具
- **仿真工具**: Verilator (必须版本 5.008)、GTKwave  
- **编译工具**: RISC-V 工具链  
- **编程语言**: Verilog HDL、C  

### 安装步骤

#### 1. 安装 Verilator

> 注意：必须使用 **5.008** 版本，否则可能无法正常仿真  

下载并安装 `verilator-5.008`。

#### 2. 安装 GTKwave

```bash
sudo apt install gtkwave
```

#### 3.安装必要库和编译工具
``` bash
sudo apt-get install build-essential
sudo apt-get install libreadline-dev
sudo apt-get install llvm-dev
sudo apt-get install g++-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

## 三、初次运行项目

### 1.克隆或下载本项目
``` bash
git clone https://github.com/Zaire404/Triathlon
```

### 2.设置环境变量
在 `~/.bashrc` 文件中添加以下内容：
``` bash
export TRIATHLON_HOME=#项目地址
export KERNELS_HOME=$TRIATHLON_HOME/am-kernels
export NEMU_HOME=$TRIATHLON_HOME/nemu
export AM_HOME=$TRIATHLON_HOME/abstract-machine
export NPC_HOME=$TRIATHLON_HOME/npc
export TEST_HOME=$KERNELS_HOME/tests
export CPU_TEST_HOME=$TEST_HOME/cpu-tests
```
添加完成后执行：
``` bash
source ~/.bashrc
```

### 3.运行 CPU 测试
可选: 重新编译CPU和am-kernels
``` bash
cd $NPC_HOME
make clean
make all

cd $CPU_TEST_HOME
make clean
```

进入 CPU 测试目录并运行：
``` bash
cd $CPU_TEST_HOME
make ARCH=riscv32e-npc ALL=dummy run
```
如果项目运行后出现一个绿色的HIT GOOD TRAP，说明程序运行成功，一切正常。
如果项目运行后出现编译报错，请自行修复，或联系我并提供报错截图，帮助修复错误。
如果项目运行后出现一个红色的HIG BAD TRAP, 说明处理器执行指令时出错，一般是处理器实现问题。