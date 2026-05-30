"""fpga_spi.py — RPi5 → FPGA SPI 드라이버 (Phase 7)
====================================================
다중 트랙 시분할 보드(mult_spi_top)로 41바이트 Mel 패킷을 전송한다.

패킷 포맷 (spi_slave.v 와 동일, CPOL=0/CPHA=0, MSB-first):
    Byte 0      : track_id  (0 ~ N_TRACKS-1)   ← spi_slave의 channel_id
    Byte 1..40  : mel_int8[0..39]              (먼저 보내는 바이트가 mel[0])

전송 1회 = CS 하강 → 41바이트 → CS 상승 (spidev xfer2가 프레임당 CS 1펄스 생성).
FPGA는 CS 상승에서 frame_rdy를 내고 해당 track_id 슬롯을 추론한다.

⚠️ 현재 FPGA RTL은 **수신 전용(MOSI)** 이며 MISO 리드백 경로가 없다.
   이상 판정 결과는 보드 LED[track_id]로만 관찰된다 → send()는 결과를 반환하지 않는다.
   (RPi에서 결과를 보고 싶으면 --dry-run의 numpy 추론을 함께 사용한다.)

spidev는 RPi5에서만 동작. 데스크톱 검증을 위해 import 실패 시 MockSpi를 쓸 수 있다.
"""
import time
import numpy as np

MEL_BYTES   = 40
PACKET_BYTES = 1 + MEL_BYTES   # track_id + 40 mel

# 프레임 간 최소 간격: FPGA control_fsm_mult는 frame_valid를 S_IDLE에서만 수용하고
# 한 타임스텝 처리에 ≈9,607클럭@50MHz ≈ 192µs 걸린다. 그 안에 다음 프레임이 오면
# busy 상태라 무시(드롭)된다 → 처리시간의 5배 마진(1ms)을 둔다. RPi sleep 지터·
# 실리콘 코너를 감안한 보수값 (Phase 8 검증 권고). 세그먼트당 31ms로 무시 가능.
FRAME_GAP_S = 0.001

# SPI SCK 기본 속도. 검증된 테스트벤치(tb_mult_spi_top)는 5MHz(50MHz 도메인 10× 오버샘플)다.
# 10MHz는 SCK 펄스폭 ~50ns vs 2단 동기화 지연으로 마진이 얇아 미검증 → 보수적으로 5MHz 기본.
DEFAULT_SPI_HZ = 5_000_000


def _build_packet(track_id, mel_int8):
    """track_id + mel[40] → 길이 41 바이트 리스트. mel_int8: [40] int8([0,127])."""
    mel = np.asarray(mel_int8, dtype=np.int8).reshape(-1)
    if mel.shape[0] != MEL_BYTES:
        raise ValueError(f"mel 길이 {mel.shape[0]} != {MEL_BYTES}")
    if not (0 <= track_id <= 255):
        raise ValueError(f"track_id {track_id} 범위 초과 (0~255)")
    # int8 → unsigned byte (값 [0,127]이라 그대로지만 안전하게 마스킹)
    return [track_id & 0xFF] + (mel.astype(np.uint8) & 0xFF).tolist()


class FpgaSpi:
    """spidev 기반 실제 전송기. RPi5 전용."""

    def __init__(self, bus=0, device=0, speed_hz=DEFAULT_SPI_HZ, mode=0):
        import spidev
        self.spi = spidev.SpiDev()
        self.spi.open(bus, device)
        self.spi.max_speed_hz = speed_hz
        self.spi.mode = mode          # CPOL=0, CPHA=0
        self.spi.bits_per_word = 8

    def send(self, track_id, mel_int8):
        """한 트랙의 Mel 세그먼트(=한 타임스텝 41B 패킷) 전송. 결과 리드백 없음."""
        self.spi.xfer2(_build_packet(track_id, mel_int8))

    def send_segment(self, track_id, seg, gap_s=FRAME_GAP_S):
        """[31,40] 세그먼트 → 31개 타임스텝 패킷을 순서대로 전송 (FPGA가 누적 추론).

        프레임 사이 gap_s 만큼 대기 — FPGA가 직전 타임스텝을 처리(busy)하는 동안
        다음 프레임이 도착하면 드롭되므로 처리시간 이상 간격을 둔다.
        """
        for ts in range(seg.shape[0]):
            self.send(track_id, seg[ts])
            if gap_s:
                time.sleep(gap_s)

    def close(self):
        self.spi.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class MockSpi:
    """FPGA 없이 파이프라인을 점검하기 위한 더미 전송기 (전송 바이트 수만 집계)."""

    def __init__(self, **_):
        self.packets = 0
        self.bytes = 0

    def send(self, track_id, mel_int8):
        pkt = _build_packet(track_id, mel_int8)
        self.packets += 1
        self.bytes += len(pkt)

    def send_segment(self, track_id, seg, gap_s=FRAME_GAP_S):
        for ts in range(seg.shape[0]):
            self.send(track_id, seg[ts])

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
