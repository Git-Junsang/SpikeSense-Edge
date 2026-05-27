## ============================================================
## nexys_a7_dual.xdc — Nexys A7 100T (XC7A100T-CSG324) 핀 제약
## Top module: dual_snn_top
## ============================================================
## 배선 (RPi5 ↔ FPGA, Pmod JA):
##   RPi5 GPIO11 (SCLK) → JA1
##   RPi5 GPIO10 (MOSI) → JA2
##   RPi5 GPIO8  (CE0)  → JA3
##   RPi5 GND           → JA GND
## ============================================================

## ---- 시스템 클럭 100 MHz (E3) ----
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports { clk }]

## ---- 리셋: CPU_RESETN 버튼 (active-low, C12) ----
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

## ---- SPI (Pmod JA, 상단 행) ----
## JA1 = SCK, JA2 = MOSI, JA3 = CS_n
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { sck  }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { mosi }]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { cs_n }]

## ---- 출력 LED ----
## LD0 = ch0 이상, LD1 = ch1 이상, LD2/LD3 = busy
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { ch0_anomaly }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { ch1_anomaly }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { ch0_busy }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { ch1_busy }]

## ---- SPI 비동기 입력 타이밍 예외 ----
## sck/mosi/cs_n은 spi_slave에서 2단 FF로 동기화 → 입력 타이밍 분석 제외
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/sck_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/cs_sync_reg*}]
set_property ASYNC_REG true [get_cells -hier -filter {NAME =~ *u_spi/mosi_sync_reg*}]
set_false_path -from [get_ports { sck mosi cs_n }]
