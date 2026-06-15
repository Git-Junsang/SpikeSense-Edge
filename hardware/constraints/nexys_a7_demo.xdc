## ============================================================
## nexys_a7_demo.xdc — Nexys A7 100T (XC7A100T-CSG324) 핀 제약
## Top module: demo_spi_top  (세그먼트 단위 판정, 2트랙 데모, 50 MHz)
## ============================================================
## nexys_a7_mult.xdc와 동일(포트·인스턴스 이름 동일: u_clkdiv/u_spi).
## 차이는 LED 의미뿐 — demo_spi_top은 세그먼트 단위로 LED를 토글한다:
##   LED0 = 트랙0 가장 최근 세그먼트(정상=off / 이상=on)
##   LED1 = 트랙1 가장 최근 세그먼트
## 배선 (RPi ↔ FPGA, Pmod JA):
##   RPi GPIO11 (SCLK) → JA1 ,  GPIO10 (MOSI) → JA2 ,  GPIO8 (CE0) → JA3
## ============================================================

## ---- 입력 클럭 100 MHz (E3) + 50 MHz 생성 클럭 ----
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports { clk }]
## clk_div2가 100MHz를 2분주 → 50MHz. BUFG 출력 핀에 생성 클럭 선언.
create_generated_clock -name clk_50 -source [get_ports { clk }] -divide_by 2 \
    [get_pins u_clkdiv/u_clkbuf/O]

## ---- 리셋: CPU_RESETN 버튼 (active-low, C12) ----
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

## ---- SPI (Pmod JA 상단 행): JA1=SCK, JA2=MOSI, JA3=CS_n ----
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { sck  }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { mosi }]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { cs_n }]

## ---- 출력 LED LD0~LD15 = 트랙 0~15 이상 플래그(세그먼트 단위) ----
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { led[0]  }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { led[1]  }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { led[2]  }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { led[3]  }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { led[4]  }]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { led[5]  }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { led[6]  }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { led[7]  }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { led[8]  }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { led[9]  }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { led[10] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { led[11] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { led[12] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { led[13] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { led[14] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { led[15] }]

## ---- SPI 비동기 입력 타이밍 예외 ----
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/sck_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/cs_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/mosi_sync_reg*}]
set_false_path -from [get_ports { sck mosi cs_n }]
