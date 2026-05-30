"""capture_mel.py — USB 마이크 캡처 + Mel Spectrogram INT8 변환 (Phase 7)
========================================================================
RPi5에서 오디오를 받아 FPGA가 기대하는 40채널 INT8 Mel 세그먼트로 만든다.

전처리는 학습(software/train.py: extract_mel_spectrogram)과 **반드시 동일**해야 한다:
    data = data - mean(data)
    S      = melspectrogram(sr=16000, n_fft=1024, hop=512, n_mels=40)  # power
    log_S  = power_to_db(S, ref=np.max)
    log_S  = log_S - min(log_S)          # 0 기준으로 시프트
    log_S  = log_S / max(log_S)          # [0,1] 정규화
    mel    = log_S.T                     # [T, 40]
    mel_int8 = round(mel * 127)          # [0,127] INT8  (RTL/SPI 전송값)

⚠️ 정규화 범위 차이(실시간 한계):
  학습은 파일 전체(min/max)로 정규화 후 31프레임씩 자른다. 실시간은 ~1초 버퍼
  하나에 대해 min/max를 잡으므로 분포가 약간 다르다 — 스트리밍에선 불가피하며,
  버퍼 길이를 세그먼트(992ms)에 맞춰 그 영향을 최소화한다.

librosa/sounddevice import는 실제 Mel 추출·마이크 캡처 시점까지 지연된다 →
골든 .npy 기반 dry-run, SPI 전송 경로는 두 패키지 없이도 모듈 로드가 가능하다.
"""
import numpy as np

# ── 학습과 동일한 피처 파라미터 (절대 변경 금지) ──────────────
SR          = 16000
N_FFT       = 1024
HOP_LENGTH  = 512
N_MELS      = 40
SEG_FRAMES  = 31                       # 31 × 32ms = 992ms (모델 입력 1세그먼트)
SEG_SAMPLES = SEG_FRAMES * HOP_LENGTH  # 15872 samples ≈ 0.992s


# ── Mel 추출 ─────────────────────────────────────────────────

def waveform_to_mel_float(y):
    """1D float 파형 → [T, 40] float32 Mel ([0,1] 정규화). 학습과 1:1 동일."""
    import librosa
    y = np.asarray(y, dtype=np.float32)
    if y.ndim > 1:
        y = y[:, 0]
    y = y - np.mean(y)

    S = librosa.feature.melspectrogram(
        y=y, sr=SR, n_fft=N_FFT, hop_length=HOP_LENGTH, n_mels=N_MELS)
    log_S = librosa.power_to_db(S, ref=np.max)
    log_S = log_S - np.min(log_S)
    max_val = np.max(log_S)
    if max_val > 1e-8:
        log_S = log_S / max_val
    return log_S.T.astype(np.float32)          # [T, 40]


def mel_float_to_int8(mel_float):
    """[T,40] float[0,1] → [T,40] int8[0,127] (RPi→FPGA 전송 양자화)."""
    q = np.rint(mel_float * 127.0)
    return np.clip(q, 0, 127).astype(np.int8)


def waveform_to_segment(y):
    """파형 → 정확히 [31, 40] int8 세그먼트 한 장.

    프레임이 31개보다 많으면 앞 31개만, 적으면 0패딩한다.
    """
    mel = mel_float_to_int8(waveform_to_mel_float(y))
    if mel.shape[0] >= SEG_FRAMES:
        return mel[:SEG_FRAMES]
    pad = np.zeros((SEG_FRAMES - mel.shape[0], N_MELS), dtype=np.int8)
    return np.vstack([mel, pad])


# ── WAV 파일 입력 (검증·데모용) ───────────────────────────────

def wav_to_segments(path):
    """WAV 파일 → [N_seg][31,40] int8 세그먼트 리스트 (학습 segment_features와 동일)."""
    import soundfile as sf
    import librosa
    data, file_sr = sf.read(path)
    if data.ndim > 1:
        data = data[:, 0]
    if file_sr != SR:
        data = librosa.resample(data, orig_sr=file_sr, target_sr=SR)
    mel = mel_float_to_int8(waveform_to_mel_float(data))
    segs = []
    for start in range(0, len(mel) - SEG_FRAMES + 1, SEG_FRAMES):
        segs.append(mel[start:start + SEG_FRAMES])
    if not segs and len(mel) > 0:                # 짧은 파일: 1장 패딩
        segs.append(waveform_to_segment(data))
    return segs


# ── 실시간 멀티 마이크 캡처 ───────────────────────────────────

class MicCapture:
    """USB 마이크 N개에서 SEG_SAMPLES 길이 버퍼를 블로킹으로 읽는다.

    각 마이크가 하나의 track_id에 매핑된다 (track_id = devices 리스트 인덱스).
    sounddevice(PortAudio)는 객체 생성 시점에만 import → 데스크톱에서도 모듈 로드 가능.
    """

    def __init__(self, devices=None, blocksize=SEG_SAMPLES):
        import sounddevice as sd
        self._sd = sd
        # devices=None → 시스템 기본 입력 1개
        self.devices = devices if devices is not None else [None]
        self.blocksize = blocksize
        self.streams = [
            sd.InputStream(device=dev, channels=1, samplerate=SR,
                           blocksize=blocksize, dtype="float32")
            for dev in self.devices
        ]

    @staticmethod
    def list_input_devices():
        """입력 가능한 (index, name) 목록 반환 — 마이크 인덱스 확인용."""
        import sounddevice as sd
        out = []
        for i, d in enumerate(sd.query_devices()):
            if d.get("max_input_channels", 0) > 0:
                out.append((i, d["name"]))
        return out

    def __enter__(self):
        for s in self.streams:
            s.start()
        return self

    def __exit__(self, *exc):
        for s in self.streams:
            s.stop(); s.close()

    def read_segments(self):
        """모든 트랙에서 1버퍼씩 읽어 [(track_id, seg[31,40] int8), ...] 반환."""
        out = []
        for tid, s in enumerate(self.streams):
            frames, _ = s.read(self.blocksize)
            out.append((tid, waveform_to_segment(frames[:, 0])))
        return out


if __name__ == "__main__":
    # 마이크 목록 출력 (RPi5에서 track_id ↔ 장치 매핑 확인)
    try:
        for idx, name in MicCapture.list_input_devices():
            print(f"  [{idx}] {name}")
    except Exception as e:
        print(f"sounddevice 사용 불가: {e}")
