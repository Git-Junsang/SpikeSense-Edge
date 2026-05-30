"""main.py — SpikeSense-Edge RPi5 실시간 파이프라인 (Phase 7)
=============================================================
USB 마이크 N개 → Mel INT8 → (FPGA SPI 전송 | numpy 추론) 다중 트랙 루프.

모드:
  (기본) FPGA 모드
      마이크 캡처 → 트랙별 41B 패킷을 SPI로 전송. 이상 판정은 보드 LED[track]로 관찰.
      RTL이 수신 전용(MISO 없음)이라 결과 리드백은 없음. --monitor로 numpy 그림자
      추론을 함께 돌려 터미널에도 예측을 표시할 수 있다.

  --dry-run  FPGA 없이 numpy(snn_infer)로 전 파이프라인 검증.
      입력: --from-wav <wav...> (트랙별 1개) 또는 마이크, 둘 다 없으면 골든 벡터로 데모.

세그먼트: 31타임스텝(992ms) = 41B 패킷 31개/트랙. 트랙별 FPGA가 버퍼 누적 후 판정.

예)
  python3 main.py --dry-run                       # 골든 벡터로 즉시 검증
  python3 main.py --dry-run --from-wav a.wav b.wav  # WAV 2트랙 numpy 추론
  python3 main.py --list-mics                      # 마이크 인덱스 확인
  python3 main.py --devices 1 2 --monitor          # 마이크 2개 → FPGA + numpy 모니터
"""
import os
import sys
import time
import argparse

import numpy as np

import capture_mel as cm
from snn_infer import SnnInfer, DEFAULT_WEIGHTS

LABELS = {0: "NORMAL", 1: "ANOMALY"}


def _fmt(track_id, label, mem_mean=None, extra=""):
    tag = "🔴 ANOMALY" if label == 1 else "🟢 normal "
    mm = f"  N={mem_mean[0]:6.1f} A={mem_mean[1]:6.1f}" if mem_mean is not None else ""
    return f"  track {track_id:2d}: {tag}{mm}{extra}"


# ── dry-run: numpy 전용 ───────────────────────────────────────

def run_dry(args):
    infer = SnnInfer(args.weights_dir)
    print("=" * 56)
    print("DRY-RUN — NumPy INT8 inference (no FPGA)")
    print("=" * 56)

    # 입력 소스 결정: WAV > 마이크 > 골든
    if args.from_wav:
        sources = []   # [(track_id, [seg,...]), ...]
        for tid, path in enumerate(args.from_wav):
            segs = cm.wav_to_segments(path)
            print(f"  track {tid}: {os.path.basename(path)} → {len(segs)} segments")
            sources.append((tid, segs))
        for tid, segs in sources:
            for i, seg in enumerate(segs):
                label, mem = infer.predict(seg)
                print(_fmt(tid, label, mem, extra=f"  [seg {i}]"))
        return

    if args.alsa is not None or args.devices is not None:
        _stream_loop(args, infer=infer, spi=None)
        return

    # 입력 없음 → 골든 벡터 데모
    print("  (no input given → golden-vector demo)")
    gdir = os.path.join(args.weights_dir, "golden")
    for tid, tag in enumerate(["normal", "anomaly"]):
        mel = np.load(os.path.join(gdir, f"{tag}_mel.npy")).astype(np.int8)
        label, mem = infer.predict(mel)
        print(_fmt(tid, label, mem, extra=f"  [golden {tag}]"))


# ── FPGA 모드 / 마이크 스트리밍 ───────────────────────────────

def _make_capture(args):
    """백엔드 선택: --alsa 주면 arecord(안정적), 아니면 sounddevice."""
    if args.alsa is not None:
        return cm.ArecordCapture(alsa_devices=args.alsa, dur_s=args.dur,
                                 gain=args.gain, verbose=args.verbose)
    devices = args.devices if args.devices else [None]
    return cm.MicCapture(devices=devices, gain=args.gain, verbose=args.verbose)


def _stream_loop(args, infer, spi):
    """마이크 N트랙을 캡처해 SPI 전송(spi 있으면) + numpy 추론(infer 있으면)."""
    mics = _make_capture(args)
    n = len(mics.devices)
    print(f"  {n} track(s)  Ctrl-C to stop")
    print("  warming up ...", flush=True)
    cm.warmup()   # mel 필터뱅크 로드 + 첫 FFT (순수 numpy라 즉시)
    with mics:
        try:
            while True:
                # 녹음 동안 listening 표시 — flush로 즉시 보이게
                print("  🎧 listening... (~1s)        ", end="\r", flush=True)
                t0 = time.time()
                segs = mics.read_segments()
                for track_id, seg in segs:
                    if spi is not None:
                        spi.send_segment(track_id, seg)
                    if infer is not None:
                        label, mem = infer.predict(seg)
                        latency = (time.time() - t0) * 1000
                        print(_fmt(track_id, label, mem,
                                   extra=f"  ({latency:.0f}ms)") + " " * 8)
                if infer is None:
                    print(f"  sent {n} track(s) → check board LED[track]" + " " * 8)
                if args.once:
                    break
        except KeyboardInterrupt:
            print("\nstopped.")


def run_fpga(args):
    from fpga_spi import FpgaSpi, MockSpi
    print("=" * 56)
    print("FPGA MODE — SPI send (result shown on board LED[track])")
    print("=" * 56)
    spi_cls = MockSpi if args.mock_spi else FpgaSpi
    infer = SnnInfer(args.weights_dir) if args.monitor else None
    if args.monitor:
        print("  --monitor: also print prediction via NumPy shadow inference")
    with spi_cls(bus=args.bus, device=args.cs, speed_hz=args.speed) as spi:
        if args.devices is None and args.alsa is None:
            print("  ⚠️ no --devices/--alsa → using default input device")
        _stream_loop(args, infer=infer, spi=spi)


# ── CLI ──────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="SpikeSense-Edge RPi5 파이프라인")
    ap.add_argument("--dry-run", action="store_true", help="FPGA 없이 numpy 추론")
    ap.add_argument("--from-wav", nargs="+", metavar="WAV",
                    help="dry-run 입력 WAV (트랙별 1개)")
    ap.add_argument("--devices", nargs="+", type=int, metavar="IDX",
                    help="USB 마이크 장치 인덱스 (sounddevice 백엔드, 트랙 순서대로)")
    ap.add_argument("--alsa", nargs="+", metavar="DEV",
                    help="ALSA 장치로 arecord 백엔드 사용 (예: plughw:2,0). Pi 권장")
    ap.add_argument("--gain", type=float, default=1.0,
                    help="소프트웨어 입력 게인 배수 (녹음이 작을 때, 예: 8.0)")
    ap.add_argument("--dur", type=float, default=1.0, help="버퍼당 녹음 길이 초 (기본 1)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="단계별 로그(샘플 수·peak·rms·지연) 출력")
    ap.add_argument("--list-mics", action="store_true", help="입력 장치 목록 출력 후 종료")
    ap.add_argument("--monitor", action="store_true",
                    help="FPGA 모드에서 numpy 그림자 추론 결과도 표시")
    ap.add_argument("--mock-spi", action="store_true", help="spidev 대신 더미 전송기")
    ap.add_argument("--once", action="store_true", help="한 버퍼만 처리 후 종료")
    ap.add_argument("--bus", type=int, default=0, help="SPI 버스 (기본 0)")
    ap.add_argument("--cs", type=int, default=0, help="SPI CS/device (기본 0=CE0)")
    ap.add_argument("--speed", type=int, default=5_000_000,
                    help="SPI 속도 Hz (기본 5MHz — 검증된 tb 속도. 10MHz는 마진 얇음)")
    ap.add_argument("--weights-dir", default=DEFAULT_WEIGHTS, help="hex 가중치 경로")
    args = ap.parse_args()

    if args.list_mics:
        try:
            for idx, name in cm.MicCapture.list_input_devices():
                print(f"  [{idx}] {name}")
        except Exception as e:
            print(f"sounddevice unavailable: {e}")
        return

    if args.dry_run:
        run_dry(args)
    else:
        run_fpga(args)


if __name__ == "__main__":
    main()
