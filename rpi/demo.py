"""demo.py — SpikeSense-Edge 실보드 데모 (Enter 스텝, 2트랙, OLED + LED)
=========================================================================
시나리오 (사용자 지정):
    Enter를 누를 때마다 한 스텝씩 진행. 각 스텝은 두 트랙에 한 세그먼트씩 전송.
        track0:  이상  정상  정상  이상
        track1:  정상  이상  정상  정상

각 스텝마다:
  1) RPi가 트랙0·트랙1의 Mel 세그먼트(31타임스텝)를 SPI로 FPGA에 전송
  2) RPi numpy 추론으로 "현재 음 정상/이상"을 판정 → OLED(1.3" I2C)에 표시
  3) FPGA는 세그먼트 단위 판정으로 LED0(=트랙0)·LED1(=트랙1)을 토글

데모 음원은 RTL과 bit-exact 검증된 골든 hw 벡터를 기본 사용 → 마이크 없이 100% 재현.
    hw_normal_mel.npy  → 정상 (스파이크 정상29:이상2)
    hw_anomaly_mel.npy → 이상 (스파이크 정상0:이상31)
실제 WAV로 바꾸려면 --normal-wav / --anomaly-wav 지정(각 파일의 첫 세그먼트 사용).

⚠️ FPGA LED가 매 세그먼트 토글되려면 **demo_spi_top** 비트스트림이어야 한다.
   (기존 mult_spi_top은 전역 Leaky Counter라 래치되어 토글 안 됨 — OLED는 정상.)

예)
  python3 demo.py                       # 실보드: SPI 전송 + OLED, Enter로 진행
  python3 demo.py --auto --interval 3   # 무인 자동 반복(3초 간격)
  python3 demo.py --mock-spi --no-oled  # 데스크톱 검증(전송/표시 없이 로직만)
  python3 demo.py --once --mock-spi --no-oled --auto --interval 0   # 1사이클 스모크
"""
import os
import sys
import time
import argparse

import numpy as np

import capture_mel as cm
from snn_infer import SnnInfer, DEFAULT_WEIGHTS

LABELS = {0: "NORMAL", 1: "ANOMALY"}

# 사용자 지정 시퀀스 — track0: 이상 정상 정상 이상 / track1: 정상 이상 정상 정상
SEQUENCE = [
    {0: "anomaly", 1: "normal"},   # step1
    {0: "normal",  1: "anomaly"},  # step2
    {0: "normal",  1: "normal"},   # step3
    {0: "anomaly", 1: "normal"},   # step4
]


def load_segments(weights_dir, normal_wav=None, anomaly_wav=None):
    """정상/이상 세그먼트 [31,40] int8 두 장 로드. WAV 지정 시 그 첫 세그먼트 사용."""
    gdir = os.path.join(weights_dir, "golden")
    if normal_wav:
        seg_n = cm.wav_to_segments(normal_wav)[0]
        print(f"  정상 음원: {os.path.basename(normal_wav)} (첫 세그먼트)")
    else:
        seg_n = np.load(os.path.join(gdir, "hw_normal_mel.npy")).astype(np.int8)
        print("  정상 음원: 골든 hw_normal_mel.npy")
    if anomaly_wav:
        seg_a = cm.wav_to_segments(anomaly_wav)[0]
        print(f"  이상 음원: {os.path.basename(anomaly_wav)} (첫 세그먼트)")
    else:
        seg_a = np.load(os.path.join(gdir, "hw_anomaly_mel.npy")).astype(np.int8)
        print("  이상 음원: 골든 hw_anomaly_mel.npy")
    return {"normal": seg_n, "anomaly": seg_a}


def run_step(spi, infer, segs, oled, step_idx, total):
    """한 스텝: 두 트랙에 세그먼트 전송 + 추론 + OLED 표시."""
    plan = SEQUENCE[step_idx]
    labels = {}
    print(f"\n── step {step_idx + 1}/{total} ─────────────────────────")
    for track_id in (0, 1):
        kind = plan[track_id]            # "normal" / "anomaly"
        seg = segs[kind]
        oled.show_sending(step_idx + 1, total, track_id)
        spi.send_segment(track_id, seg)  # 31 타임스텝 SPI 전송
        label, mem = infer.predict(seg)  # OLED용 per-세그먼트 분류(막전위 argmax)
        labels[track_id] = label
        led = "🔴 LED ON " if label == 1 else "⚫ off    "
        print(f"  track{track_id} ← {kind:8s} pred={LABELS[label]:7s}  "
              f"LED{track_id} {led}  (mem N={mem[0]:6.1f} A={mem[1]:6.1f})")
    oled.show_status(step_idx + 1, total, labels[0], labels[1])
    return labels


def run_loop(args, spi, infer, segs, oled):
    total = len(SEQUENCE)
    print("\n" + "=" * 56)
    if args.auto:
        print(f"AUTO 모드 — {args.interval}초 간격 자동 반복 (Ctrl-C 종료)")
    else:
        print("MANUAL 모드 — Enter=다음 음 전송 / q+Enter=종료")
    print("=" * 56)

    step = 0
    try:
        while True:
            if args.auto:
                if args.interval:
                    time.sleep(args.interval)
            else:
                cmd = input(f"[{step + 1}/{total}] Enter로 전송 (q=종료) > ")
                if cmd.strip().lower() == "q":
                    break
            run_step(spi, infer, segs, oled, step, total)
            step += 1
            if step >= total:
                step = 0
                if args.once:
                    print("\n1 사이클 완료 (--once) → 종료")
                    break
                print("  ── 한 사이클 완료, 처음부터 반복 ──")
    except KeyboardInterrupt:
        print("\n중지됨.")


def main():
    ap = argparse.ArgumentParser(description="SpikeSense-Edge 실보드 데모")
    # SPI
    ap.add_argument("--bus", type=int, default=0, help="SPI 버스 (기본 0)")
    ap.add_argument("--cs", type=int, default=0, help="SPI CS (기본 0=CE0)")
    ap.add_argument("--speed", type=int, default=5_000_000, help="SPI 속도 Hz (기본 5MHz)")
    ap.add_argument("--mock-spi", action="store_true", help="spidev 대신 더미 전송기(데스크톱)")
    # OLED
    ap.add_argument("--no-oled", action="store_true", help="OLED 비활성화(콘솔만)")
    ap.add_argument("--oled-controller", default="sh1106",
                    choices=["sh1106", "ssd1306"], help="OLED 컨트롤러 (1.3\"=sh1106)")
    ap.add_argument("--oled-addr", default="0x3c", help="OLED I2C 주소 (기본 0x3c)")
    ap.add_argument("--oled-port", type=int, default=1, help="I2C 포트 (기본 1)")
    # 진행
    ap.add_argument("--auto", action="store_true", help="Enter 없이 자동 진행/반복")
    ap.add_argument("--interval", type=float, default=3.0, help="--auto 간격 초 (기본 3)")
    ap.add_argument("--once", action="store_true", help="1 사이클(4스텝)만 수행 후 종료")
    # 음원
    ap.add_argument("--normal-wav", help="정상 음원 WAV (미지정 시 골든)")
    ap.add_argument("--anomaly-wav", help="이상 음원 WAV (미지정 시 골든)")
    ap.add_argument("--weights-dir", default=DEFAULT_WEIGHTS, help="가중치/골든 경로")
    args = ap.parse_args()

    from fpga_spi import FpgaSpi, MockSpi
    from oled_display import OledDisplay

    print("=" * 56)
    print("SpikeSense-Edge — 2트랙 OLED+LED 데모")
    print("=" * 56)
    print("시퀀스:  track0: 이상 정상 정상 이상")
    print("         track1: 정상 이상 정상 정상")

    infer = SnnInfer(args.weights_dir)
    segs = load_segments(args.weights_dir, args.normal_wav, args.anomaly_wav)

    oled = OledDisplay(controller=args.oled_controller, i2c_port=args.oled_port,
                       i2c_addr=int(args.oled_addr, 0), enabled=not args.no_oled)
    oled.show_lines(["SpikeSense-Edge", "", "ready.", "press Enter ..."])

    spi_cls = MockSpi if args.mock_spi else FpgaSpi
    if args.mock_spi:
        print("  [SPI] MockSpi (실제 전송 없음)")
    else:
        print(f"  [SPI] spidev bus{args.bus} CE{args.cs} @ {args.speed} Hz")
        print("  TIP: 데모 시작 전 보드 CPU_RESETN을 한 번 눌러 카운터를 초기화하세요.")

    with spi_cls(bus=args.bus, device=args.cs, speed_hz=args.speed) as spi:
        run_loop(args, spi, infer, segs, oled)

    oled.show_lines(["SpikeSense-Edge", "", "demo finished."])


if __name__ == "__main__":
    main()
