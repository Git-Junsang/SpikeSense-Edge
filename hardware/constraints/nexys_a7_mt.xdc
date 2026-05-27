## ============================================================
## nexys_a7_mt.xdc — Nexys A7 100T (XC7A100T-CSG324) 핀 제약
## Top module: mt_spi_top  (다중 트랙 시분할, 50 MHz)
## ============================================================
## 배선 (RPi5 ↔ FPGA, Pmod JA):
##   RPi5 GPIO11 (SCLK) → JA1 ,  GPIO10 (MOSI) → JA2 ,  GPIO8 (CE0) → JA3
## ============================================================

## ---- 입력 클럭 100 MHz (E3) + 50 MHz 생성 클럭 ----
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports { clk }]
## clk_div2가 100MHz를 2분주 → 50MHz. BUFG 출력 핀에 생성 클럭 선언.
## 모든 SNN/SPI 로직은 이 50MHz(20ns)로 분석된다 → 임계경로 15.3ns 여유.
create_generated_clock -name clk_50 -source [get_ports { clk }] -divide_by 2 \
    [get_pins u_clkdiv/u_clkbuf/O]

## ---- 리셋: CPU_RESETN 버튼 (active-low, C12) ----
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

## ---- SPI (Pmod JA 상단 행): JA1=SCK, JA2=MOSI, JA3=CS_n ----
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { sck  }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { mosi }]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { cs_n }]

## ---- 출력 LED LD0~LD15 = 트랙 0~15 이상 플래그 ----
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
## sck/mosi/cs_n은 spi_slave에서 2단 FF로 동기화 → 입력 타이밍 분석 제외
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/sck_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/cs_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/mosi_sync_reg*}]
set_false_path -from [get_ports { sck mosi cs_n }]
