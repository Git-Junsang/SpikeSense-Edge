"""hw_test.py — Phase 8 RPi5 ↔ FPGA SPI 통합 테스트 (LED 관찰 기반)
====================================================================
마이크/모델 정확도와 무관하게 **RPi→FPGA SPI 링크 + 트랙 디먹스 + 이상 판정**만
검증한다. FPGA는 수신 전용(MISO 없음)이라 결과는 보드 LED로 눈으로 확인한다.

전제: FPGA에 mult_spi_top 비트스트림이 프로그램되어 있고, 아래 배선이 되어 있을 것.

  RPi5 (BCM)          Nexys A7 Pmod JA
  ---------           ----------------
  GPIO11 SCLK   →     JA1  (FPGA C17, sck)
  GPIO10 MOSI   →     JA2  (FPGA D18, mosi)
  GPIO8  CE0    →     JA3  (FPGA E18, cs_n)
  GND           →     JA GND
  LED[t] = 트랙 t 이상 플래그 (cnt_anomaly > cnt_normal)

HW 이상 판정 = L3 스파이크 Leaky Counter (SW 막전위 argmax와 규칙 다름).
hw_anomaly_mel.npy(cnt_a≫cnt_n) / hw_normal_mel.npy(cnt_n≫cnt_a)를 전용 입력으로 사용.
※ 카운터는 전역 리셋에서만 0 → 테스트 전 보드 CPU_RESETN(C12) 한 번 눌러 초기화 권장.

모드:
  wiring   — 인식 가능한 패턴을 계속 전송 (오실로스코프/로직애널라이저로 SCK/MOSI/CS 확인)
  led      — anomaly→트랙A(LED ON), normal→트랙B(LED OFF) 전송 후 기대 LED 안내
  sweep    — 트랙 0..N-1에 차례로 anomaly 전송 → LED가 하나씩 켜짐 (트랙 디먹스 검증)

예)
  python3 hw_test.py wiring
  python3 hw_test.py led                 # 트랙0=normal(LED0 off), 트랙1=anomaly(LED1 on)
  python3 hw_test.py sweep --tracks 8
  python3 hw_test.py led --mock           # FPGA 없이 전송 동작만 점검
"""
import os
import sys
import time
import argparse
import numpy as np

from fpga_spi import FpgaSpi, MockSpi

_HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.normpath(os.path.join(_HERE, "..", "hardware", "src", "weights", "golden"))

WIRING = """  RPi5 GPIO11(SCLK)→JA1(C17 sck) · GPIO10(MOSI)→JA2(D18 mosi) · GPIO8(CE0)→JA3(E18 cs_n) · GND→GND
  LED[t] = track t anomaly flag   |   reset: CPU_RESETN(C12)"""


def _load(tag):
    p = os.path.join(GOLDEN, f"hw_{tag}_mel.npy")
    if not os.path.exists(p):
        sys.exit(f"테스트 벡터 없음: {p}\n  software/make_hw_test_vectors.py 를 먼저 실행하세요.")
    return np.load(p).astype(np.int8)        # [31,40]


def _spi(args):
    if args.mock:
        return MockSpi()
    return FpgaSpi(bus=args.bus, device=args.cs, speed_hz=args.speed)


def mode_wiring(args, spi):
    """track 0에 램프 패턴(0..39)을 반복 전송 — 신호선 검증용."""
    ramp = np.arange(40, dtype=np.int8)      # 식별 쉬운 0,1,2,...,39
    print("  wiring test: track0에 ramp(0..39) 프레임 반복 전송")
    print("  → 로직애널라이저/스코프로 SCK·MOSI·CS_n 토글 확인. Ctrl-C 종료.")
    sent = 0
    try:
        while True:
            spi.send(0, ramp)
            time.sleep(0.001)
            sent += 1
            if sent % 200 == 0:
                print(f"    sent {sent} frames", flush=True)
            if args.once and sent >= 1:
                break
    except KeyboardInterrupt:
        print(f"\n  stopped ({sent} frames).")


def mode_led(args, spi):
    """anomaly→트랙A(LED on), normal→트랙B(LED off)."""
    anom = _load("anomaly")
    norm = _load("normal")
    a_trk, n_trk = args.anom_track, args.norm_track
    print(f"  ⚠ 먼저 보드 CPU_RESETN(C12)을 한 번 눌러 카운터를 초기화하세요.")
    print(f"  전송: track{n_trk}=normal ×{args.repeat},  track{a_trk}=anomaly ×{args.repeat}")
    for _ in range(args.repeat):
        spi.send_segment(n_trk, norm)
        spi.send_segment(a_trk, anom)
    print(f"\n  기대 LED 상태:")
    print(f"    🔴 LED{a_trk} = ON   (track{a_trk}: anomaly, cnt_a≫cnt_n)")
    print(f"    ⚫ LED{n_trk} = OFF  (track{n_trk}: normal,  cnt_n≫cnt_a)")
    print(f"  → 실제 보드 LED가 위와 같으면 SPI 링크·디먹스·이상판정 전 경로 PASS.")


def mode_sweep(args, spi):
    """트랙 0..N-1에 차례로 anomaly 전송 → LED가 하나씩 켜짐."""
    anom = _load("anomaly")
    n = args.tracks
    print(f"  ⚠ 먼저 CPU_RESETN(C12)으로 초기화. 트랙 0..{n-1}에 anomaly 순차 전송.")
    for t in range(n):
        for _ in range(args.repeat):
            spi.send_segment(t, anom)
        print(f"    track{t} 전송 → 🔴 LED{t} ON 이어야 함  (이전 LED는 유지)", flush=True)
        time.sleep(args.dwell)
    print(f"\n  기대: LED0..{n-1} 가 순서대로 켜져 누적 점등 → 트랙 디먹스·격리 PASS.")


def main():
    ap = argparse.ArgumentParser(description="Phase 8 RPi↔FPGA SPI 통합 테스트")
    ap.add_argument("mode", choices=["wiring", "led", "sweep"])
    ap.add_argument("--anom-track", type=int, default=1)
    ap.add_argument("--norm-track", type=int, default=0)
    ap.add_argument("--tracks", type=int, default=8, help="sweep 트랙 수")
    ap.add_argument("--repeat", type=int, default=3, help="버퍼 반복 전송 횟수")
    ap.add_argument("--dwell", type=float, default=0.8, help="sweep 트랙당 대기 초")
    ap.add_argument("--mock", action="store_true", help="FPGA 없이 전송 동작만 점검")
    ap.add_argument("--once", action="store_true", help="wiring: 1프레임만")
    ap.add_argument("--bus", type=int, default=0)
    ap.add_argument("--cs", type=int, default=0)
    ap.add_argument("--speed", type=int, default=5_000_000, help="SPI Hz (기본 5MHz, 검증값)")
    args = ap.parse_args()

    print("=" * 60)
    print(f"Phase 8 HW 통합 테스트 — mode={args.mode}")
    print(WIRING)
    print("=" * 60)

    with _spi(args) as spi:
        {"wiring": mode_wiring, "led": mode_led, "sweep": mode_sweep}[args.mode](args, spi)

    if args.mock:
        print(f"\n  [mock] packets={spi.packets} bytes={spi.bytes}")


if __name__ == "__main__":
    main()
