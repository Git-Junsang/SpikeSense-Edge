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
import numpy as np

MEL_BYTES   = 40
PACKET_BYTES = 1 + MEL_BYTES   # track_id + 40 mel


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

    def __init__(self, bus=0, device=0, speed_hz=10_000_000, mode=0):
        import spidev
        self.spi = spidev.SpiDev()
        self.spi.open(bus, device)
        self.spi.max_speed_hz = speed_hz
        self.spi.mode = mode          # CPOL=0, CPHA=0
        self.spi.bits_per_word = 8

    def send(self, track_id, mel_int8):
        """한 트랙의 Mel 세그먼트(=한 타임스텝 41B 패킷) 전송. 결과 리드백 없음."""
        self.spi.xfer2(_build_packet(track_id, mel_int8))

    def send_segment(self, track_id, seg):
        """[31,40] 세그먼트 → 31개 타임스텝 패킷을 순서대로 전송 (FPGA가 누적 추론)."""
        for ts in range(seg.shape[0]):
            self.send(track_id, seg[ts])

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

    def send_segment(self, track_id, seg):
        for ts in range(seg.shape[0]):
            self.send(track_id, seg[ts])

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
