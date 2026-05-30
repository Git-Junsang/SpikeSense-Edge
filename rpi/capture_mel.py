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
    """USB 마이크 N개에서 ~992ms 버퍼를 블로킹으로 읽어 16kHz Mel 세그먼트로 만든다.

    각 마이크가 하나의 track_id에 매핑된다 (track_id = devices 리스트 인덱스).
    sounddevice(PortAudio)는 객체 생성 시점에만 import → 데스크톱에서도 모듈 로드 가능.

    ⚠️ USB 마이크는 보통 16kHz를 직접 지원하지 않으므로(48k/44.1k만 가능),
       장치가 지원하는 샘플레이트로 녹음한 뒤 16kHz로 리샘플링한다.
    """

    # 16k 직접 지원이 안 될 때 시도할 후보 (높은 품질 순)
    _SR_CANDIDATES = (SR, 48000, 44100, 32000, 22050, 16000)

    def __init__(self, devices=None, gain=1.0, verbose=False):
        import sounddevice as sd
        self._sd = sd
        # devices=None → 시스템 기본 입력 1개
        self.devices = devices if devices is not None else [None]
        self.gain = gain
        self.verbose = verbose
        self.cap_srs = [self._pick_samplerate(dev) for dev in self.devices]
        # 각 트랙: 16kHz 기준 SEG_SAMPLES와 같은 길이(시간)를 캡처 레이트로 환산
        self.blocks = [int(round(SEG_SAMPLES * sr / SR)) for sr in self.cap_srs]
        for dev, sr in zip(self.devices, self.cap_srs):
            note = "" if sr == SR else " → resample to 16kHz"
            print(f"  mic {dev}: capturing at {sr}Hz{note}")

    def _pick_samplerate(self, dev):
        """장치가 실제로 열 수 있는 입력 샘플레이트를 고른다."""
        sd = self._sd
        # 1) 장치 기본값 우선 시도
        try:
            ds = int(sd.query_devices(dev, "input")["default_samplerate"])
            cands = (ds,) + self._SR_CANDIDATES
        except Exception:
            cands = self._SR_CANDIDATES
        for sr in cands:
            try:
                sd.check_input_settings(device=dev, samplerate=sr,
                                        channels=1, dtype="float32")
                return sr
            except Exception:
                continue
        return SR  # 최후 — 그래도 안 되면 열 때 에러로 드러남

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
        return self

    def __exit__(self, *exc):
        try:
            self._sd.stop()
        except Exception:
            pass

    def _record(self, dev, sr, blk):
        """sd.rec로 blk 프레임 고정 녹음 + 워치독 타임아웃.

        InputStream.read는 '데이터 올 때까지 무한 대기'라 마이크/ALSA가 프레임을
        안 주면 영영 안 돌아온다. sd.rec는 디바이스 클럭 기준 고정 길이라 무음이라도
        끝난다. 그래도 장치가 완전히 멈춰있을 때를 대비해 스레드 타임아웃으로 보호.
        """
        import threading
        sd = self._sd
        box = {}

        def worker():
            try:
                rec = sd.rec(blk, samplerate=sr, channels=1, dtype="float32", device=dev)
                sd.wait()
                box["y"] = rec[:, 0]
            except Exception as e:
                box["err"] = e

        t = threading.Thread(target=worker, daemon=True)
        t.start()
        timeout = blk / sr * 3.0 + 2.0          # 기대 길이의 3배 + 2초
        t.join(timeout)
        if t.is_alive():
            sd.stop()
            raise RuntimeError(
                f"mic {dev}: recording timed out (no audio from device). "
                f"`arecord -l`로 장치 확인 / 케이블·권한(spi,audio 그룹) 점검")
        if "err" in box:
            raise box["err"]
        return box["y"]

    def read_segments(self):
        """모든 트랙에서 1버퍼씩 녹음해 [(track_id, seg[31,40] int8), ...] 반환.

        캡처 레이트 ≠ 16kHz면 16kHz로 리샘플링 후 Mel 변환한다.
        리샘플은 scipy 폴리페이즈(resample_poly) 사용 — librosa.resample의 numba
        JIT 콜드스타트(Pi에서 수십 초)를 회피해 실시간성을 확보한다.
        """
        from math import gcd
        from scipy.signal import resample_poly
        out = []
        for tid, (dev, sr, blk) in enumerate(zip(self.devices, self.cap_srs, self.blocks)):
            y = self._record(dev, sr, blk)
            if self.gain != 1.0:
                y = np.clip(y * self.gain, -1.0, 1.0)
            if self.verbose:
                pk = float(np.max(np.abs(y))) if len(y) else 0.0
                rms = float(np.sqrt(np.mean(y ** 2))) if len(y) else 0.0
                print(f"  [t{tid}] {len(y)} smp @ {sr}Hz  peak={pk:.4f} rms={rms:.4f}"
                      f"{'  ⚠ 매우 작음(게인↑)' if pk < 0.02 else ''}", flush=True)
            if sr != SR:
                g = gcd(SR, sr)
                y = resample_poly(y, SR // g, sr // g)
            out.append((tid, waveform_to_segment(y)))
        return out


# ── arecord(ALSA) 기반 캡처 — PortAudio가 불안정한 Pi용 ────────

class ArecordCapture:
    """`arecord` 서브프로세스로 고정 길이 녹음. PortAudio(sounddevice)가 데이터를
    안 주고 무한 대기하는 환경에서 안정적인 대안.

    plughw 장치를 16kHz로 직접 녹음 → ALSA가 리샘플하므로 scipy 불필요.
    track_id = alsa_devices 리스트 인덱스.
    """

    def __init__(self, alsa_devices=None, dur_s=1.0, gain=1.0, verbose=False):
        self.devices = alsa_devices if alsa_devices else [self.autodetect()]
        self.dur_s = max(1, int(round(dur_s)))    # arecord -d 는 정수 초
        self.gain = gain
        self.verbose = verbose

    @staticmethod
    def autodetect():
        """`arecord -l`에서 첫 캡처 장치 → 'plughw:CARD,DEV' 문자열."""
        import subprocess, re
        out = subprocess.run(["arecord", "-l"], capture_output=True,
                             text=True).stdout
        m = re.search(r"card (\d+):.*?device (\d+):", out)
        if not m:
            raise RuntimeError("arecord -l: 캡처 장치를 찾을 수 없음")
        return f"plughw:{m.group(1)},{m.group(2)}"

    def __enter__(self):
        for tid, dev in enumerate(self.devices):
            print(f"  mic track{tid} (arecord {dev}): 16kHz")
        return self

    def __exit__(self, *exc):
        pass

    def _record(self, dev):
        """arecord로 dur_s초 raw PCM(S16_LE mono 16k) 캡처 → float[-1,1]."""
        import subprocess
        cmd = ["arecord", "-q", "-D", dev, "-f", "S16_LE", "-c", "1",
               "-r", str(SR), "-t", "raw", "-d", str(self.dur_s)]
        try:
            p = subprocess.run(cmd, capture_output=True,
                               timeout=self.dur_s * 3 + 5)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"arecord timed out on {dev} (장치 무응답)")
        if p.returncode != 0:
            raise RuntimeError(
                f"arecord 실패({dev}): {p.stderr.decode(errors='ignore')[:200]}")
        y = np.frombuffer(p.stdout, dtype="<i2").astype(np.float32) / 32768.0
        if self.gain != 1.0:
            y = np.clip(y * self.gain, -1.0, 1.0)
        return y

    def read_segments(self):
        out = []
        for tid, dev in enumerate(self.devices):
            t0 = _now()
            if self.verbose:
                print(f"  [t{tid}] recording {self.dur_s}s @ {dev} ...",
                      flush=True)
            y = self._record(dev)
            if self.verbose:
                pk = float(np.max(np.abs(y))) if len(y) else 0.0
                rms = float(np.sqrt(np.mean(y ** 2))) if len(y) else 0.0
                dt = (_now() - t0) * 1000 if t0 is not None else -1
                print(f"  [t{tid}] {len(y)} smp  peak={pk:.4f} rms={rms:.4f}"
                      f"  ({dt:.0f}ms){'  ⚠ 매우 작음(게인↑ 필요)' if pk < 0.02 else ''}",
                      flush=True)
            out.append((tid, waveform_to_segment(y)))
        return out


def _now():
    """time.time() — Date 의존 회피용 헬퍼 (모듈 상단 import 불필요화)."""
    import time
    return time.time()


def warmup():
    """librosa import + 첫 Mel 연산을 미리 수행.

    Pi에서 librosa 첫 호출(import numba/scipy + JIT)이 ~15초 걸려 첫 추론이 멈춘 듯
    보인다. 루프 진입 전에 더미 입력으로 한 번 돌려 그 비용을 시작 시점으로 옮긴다.
    """
    waveform_to_segment(np.zeros(SEG_SAMPLES, np.float32))


if __name__ == "__main__":
    # 마이크 목록 출력 (RPi5에서 track_id ↔ 장치 매핑 확인)
    try:
        for idx, name in MicCapture.list_input_devices():
            print(f"  [{idx}] {name}")
    except Exception as e:
        print(f"sounddevice unavailable: {e}")
    try:
        print(f"arecord 기본 장치: {ArecordCapture.autodetect()}")
    except Exception as e:
        print(f"arecord unavailable: {e}")
