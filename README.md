# SpikeSense-Edge

**FPGA 엣지 기반 SNN 음향 이상 감지 시스템**

클라우드 없이 엣지 단에서 팬·기계 설비의 이상음을 실시간으로 감지합니다.  
PyTorch로 학습한 PLIF-T SNN 모델을 Xilinx Artix-7 FPGA에 이식하는 것을 목표로 합니다.

---

## 시스템 구성

```
[USB 마이크 ×2]
   │ 16kHz PCM (채널 독립)
   ▼
[Raspberry Pi 5]
   ├─ CH0: Mel Spectrogram → INT8 × 40ch
   └─ CH1: Mel Spectrogram → INT8 × 40ch
   │ SPI (5MHz, 41바이트 패킷/프레임)
   ▼
[Nexys A7 100T FPGA]
   ├─ SPI slave → dual_snn_top
   │    ├─ snn_top #0 (CH0) → LED0
   │    └─ snn_top #1 (CH1) → LED1
   ▼
anomaly_flag × 2 (0=정상 / 1=이상)
```

| 구성 요소 | 역할 |
|-----------|------|
| Raspberry Pi 5 | 2채널 오디오 수집, Mel Spectrogram 전처리, SPI 전송 |
| Nexys A7 100T (Artix-7) | PLIF-T SNN 추론 가속 (2채널 독립 동시 처리) |

---

## 모델 아키텍처

**PLIF-T SNN (Parametric LIF with Learnable Threshold)**

```
Input (40) → Hidden1 (128) → Hidden2 (32) → Output (2)
              PLIF-T          PLIF-T         PLIF-T
```

- 입력: ~1초 오디오 버퍼 (31 × 32ms = 992ms) → 40채널 Log-Mel Spectrogram → 31 타임스텝
- 뉴런: β(감쇠율)와 V_th(발화 임계값)가 모두 학습 파라미터
- 분류: 타임스텝별 막전위 평균의 argmax → 정상(0) / 이상(1)
- 총 가중치: 9,280개 (하드웨어에서 INT8 양자화)

### 학습 설정

| 항목 | 값 |
|------|-----|
| Loss | Focal Loss (γ=2, 클래스 빈도 기반 가중치) |
| Optimizer | Adam (lr=0.002, weight_decay=1e-5) |
| Scheduler | Cosine Annealing |
| 데이터 증강 | SpecAugment (주파수·시간 마스킹 15%), Mixup (α=0.2) |
| 피처 | 40-mel, FFT=1024, hop=512, 16kHz |

---

## 디렉토리 구조

```
SpikeSense-Edge/
├── software/
│   ├── snn_model.py            # PLIF-T SNN 모델 정의 (PyTorch)
│   ├── train.py                # 학습 루프 (Focal Loss, Mixup, Resume 지원)
│   ├── test_model_numpy.py     # NumPy 순전파 검증 (PyTorch 불필요)
│   ├── export_weights.py       # INT8 가중치 추출 → hex 파일
│   ├── best_model_mimii_v2-1.pth  # 최고 성능 모델 (MIMII 데이터셋)
│   ├── data_dcase/             # 정식 학습 데이터 (DCASE — normal/, anomaly/)
│   └── data_mimii/             # 경량 검증 데이터 (MIMII)
│
├── hardware/
│   ├── src/                    # 신규 RTL — Mel + PLIF-T (Phase 4 완료)
│   │   └── weights/            # INT8 가중치 hex + 골든 벡터
│   ├── constraints/            # Vivado XDC 핀 제약 (Phase 5~6)
│   ├── fpga/                   # Vivado 프로젝트 자동화 tcl
│   ├── testbench/              # 테스트벤치 .v 소스
│   └── sim/                    # 컴파일 결과물 (.gitignore)
│
├── rpi/                        # RPi5 소프트웨어 (Phase 7 완료 / 데모 Phase 9)
│   ├── requirements.txt        # numpy, scipy, soundfile, sounddevice, spidev (librosa 불필요)
│   ├── capture_mel.py          # USB 마이크 캡처 + Mel INT8 (순수 numpy, sounddevice/arecord)
│   ├── snn_infer.py            # NumPy INT8 추론 (dry-run, RTL bit-exact)
│   ├── fpga_spi.py             # SPI 드라이버 (5MHz, 41B 패킷, track_id, 프레임 간격)
│   ├── main.py                 # 메인 루프 (다중 트랙 파이프라인, --dry-run)
│   ├── hw_test.py              # Phase 8 SPI 통합 테스트 (wiring/led/sweep)
│   └── demo.py                 # 터미널 UI 데모 (Phase 9 예정)
│
└── CLAUDE.md                   # AI 코딩 보조 가이드
```

---

## 시작하기

### 요구 사항

```bash
pip install torch numpy librosa soundfile scikit-learn
```

### 데이터 준비

```
data_dcase/
├── normal/     # 정상 작동 WAV 파일 (16kHz 권장)
└── anomaly/    # 이상 작동 WAV 파일
```

지원 데이터셋: [MIMII Dataset](https://zenodo.org/record/3384388), [DCASE 2020 Task 2](https://dcase.community/challenge2020/task2-unsupervised-detection-of-anomalous-sounds)

### 학습

```bash
cd software

# 새로 학습
python train.py --data_dir data_dcase --model_name my_model.pth --epochs 150 --batch_size 256

# 이어서 학습 (epochs는 추가가 아닌 최종 목표 에포크)
python train.py --data_dir data_dcase --model_name my_model.pth --epochs 300 --resume
```

| 옵션 | 설명 | 기본값 |
|------|------|--------|
| `--data_dir` | 데이터 최상위 폴더 (하위에 normal/, anomaly/ 필수) | 필수 |
| `--model_name` | 저장/불러올 가중치 파일명 | `best_model.pth` |
| `--epochs` | 최종 목표 에포크 수 | 150 |
| `--resume` | 체크포인트에서 에포크·LR·가중치 이어서 학습 | False |
| `--batch_size` | 배치 크기 | 256 |
| `--lr` | 초기 학습률 (Cosine Annealing 적용) | 0.002 |
| `--n_mels` | Mel 밴드 수 및 입력 채널 | 40 |
| `--segment_ms` | 데이터 분할 단위 (ms) | 992 |

### 순전파 동작 확인 (PyTorch 없이)

```bash
cd software
python test_model_numpy.py
```

---

## 하드웨어 (FPGA RTL)

> **현재 상태**: **Phase 6 완료** — 100MHz 타이밍 미달(WNS −5.498ns)을 **다중 트랙 시분할(TDM) @50MHz**로 해결.  
> 단일 데이터패스를 N트랙이 공유(트랙별 막전위·이상카운터만 복제). 50MHz 합성·구현·비트스트림 완주 → **WNS +4.072ns(타이밍 닫힘)**, LUT 2,033·FF 4,605·BRAM36 12·DSP 1.  
> 검증: iverilog(tb_mult_snn_top 496/496, tb_mult_spi_top 8/8, tb_mult_selftest PASS) + **보드 자가진단(mult_selftest_top) 실리콘 PASS** — RPi 없이 골든 입력으로 LED15 점등 확인.  
> ⚠️ Vivado 프로젝트 경로는 **ASCII 필수**(한글 경로면 합성 run 크래시).  
> **Phase 7 완료** — RPi5 소프트웨어(`rpi/`): 다중트랙 Mel→SPI 전송 + numpy `--dry-run`(골든 bit-exact PASS). Phase 8~9: 실제 보드 통합 → 데모.

### RTL 설계 사양 (`hardware/src/`)

| 항목　　　　　　| 사양　　　　　　　　　　　　　　　　　　　　|
| -----------------| ---------------------------------------------|
| 타깃 보드　　　 | Nexys A7 100T (XC7A100T)　　　　　　　　　　|
| 입력 인터페이스 | SPI slave (5MHz, 41바이트 패킷)　　　　　　　|
| 동작 클럭 | 50 MHz (보드 100MHz E3 → `clk_div2` 2분주) |
| 채널/트랙 | 다중 트랙 시분할 (`N_TRACKS`, 기본 64) — 단일 데이터패스 공유. 초기 듀얼채널(snn_top×2)은 동결 |
| 처리 방식 | 시분할(Time-Multiplexing) — 162뉴런/타임스텝, 타임스텝당 ≈9,607클럭 |
| 가중치 저장 | BRAM (9,280 × INT8 ≈ 74Kbits, 전 트랙 공유) |
| 막전위 형식 | 16-bit signed, Soft Reset (트랙별 BRAM) |
| 이상 판정 | 트랙별 Leaky Counter (`cnt_anomaly > cnt_normal`) |
| 출력 | `anomaly_flags[N]` → LED. 보드 자가진단 시 LED15=PASS |

### 시뮬레이션 (Testbench)

#### 테스트벤치 파일 (`hardware/testbench/`)

| 파일 | 대상 모듈 | TC 수 | 외부 파일 필요 |
|------|-----------|-------|--------------|
| `plift_core_tb.v` | PLIF-T 뉴런 단독 | 12 | 없음 |
| `mac_unit_tb.v` | MAC 단독 | — | 없음 |
| `phase2_tb.v` | Phase 2 핵심 모듈 6종 | 32 | `weights/*.hex` |
| `phase3_tb.v` | Phase 3 control_fsm·snn_top | 57 | `weights/*.hex` |
| `tb_snn_top.v` | 전체 시스템 골든 벡터 검증 | 312 | `weights/golden/*.hex` |
| `tb_dual_snn_top.v` | 듀얼채널 + SPI (mode 0) 검증 | 314 | `weights/golden/*.hex` |
| `tb_mult_snn_top.v` | 다중 트랙 시분할 코어 (4트랙 인터리빙 골든) | 496 | `weights/golden/*.hex` |
| `tb_mult_spi_top.v` | SPI 통합 시분할 (clk분주 + track 디먹스) | 8 | `weights/golden/*.hex` |
| `tb_mult_selftest.v` | 보드 자가진단(mult_selftest_top) 시뮬 — 골든 스파이크 62개 자체 비교 → LED15=PASS | PASS/FAIL | `weights/golden/*.hex` |

#### A. VSCode 터미널 (iverilog)

```bash
mkdir -p hardware/sim

# 단독 모듈 — 외부 파일 불필요, 즉시 실행
/usr/bin/iverilog -g2001 -o hardware/sim/plift_core_tb \
    hardware/testbench/plift_core_tb.v hardware/src/plift_core.v
/usr/bin/vvp hardware/sim/plift_core_tb

/usr/bin/iverilog -g2001 -o hardware/sim/mac_unit_tb \
    hardware/testbench/mac_unit_tb.v hardware/src/mac_unit.v
/usr/bin/vvp hardware/sim/mac_unit_tb

# Phase 2 (weights/ hex 파일 필요)
/usr/bin/iverilog -g2001 -o hardware/sim/phase2_tb \
    hardware/testbench/phase2_tb.v hardware/src/*.v
/usr/bin/vvp hardware/sim/phase2_tb

# Phase 3
/usr/bin/iverilog -g2001 -o hardware/sim/phase3_tb \
    hardware/testbench/phase3_tb.v hardware/src/*.v
/usr/bin/vvp hardware/sim/phase3_tb

# Phase 4 — 전체 시스템 골든 벡터 검증
/usr/bin/iverilog -g2001 -o hardware/sim/snn_top \
    hardware/testbench/tb_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/snn_top

# Phase 5 — 듀얼채널 + SPI 인터페이스 검증
/usr/bin/iverilog -g2001 -o hardware/sim/dual_snn_top \
    hardware/testbench/tb_dual_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/dual_snn_top

# Phase 6-2 — 다중 트랙 시분할 (50MHz): 코어 골든 검증
/usr/bin/iverilog -g2001 -o hardware/sim/mult_snn_top \
    hardware/testbench/tb_mult_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_snn_top
# Phase 6-2 — SPI 통합(clk분주 + track 디먹스) 검증
/usr/bin/iverilog -g2001 -o hardware/sim/mult_spi_top \
    hardware/testbench/tb_mult_spi_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_spi_top

# Phase 6-2 — 보드 자가진단(mult_selftest_top) 시뮬 (RPi 없이 LED15=PASS)
/usr/bin/iverilog -g2001 -o hardware/sim/mult_selftest \
    hardware/testbench/tb_mult_selftest.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_selftest
```

#### B. Vivado (Windows / SMB Z:/ 마운트)

> 서버의 `/data` 폴더가 Windows에서 `Z:/`로 마운트되어 있어야 합니다.

1. **소스 추가**: Sources → Add Sources → Simulation  
   - `Z:\...\SpikeSense-Edge\hardware\testbench\plift_core_tb.v`  
   - `Z:\...\SpikeSense-Edge\hardware\src\plift_core.v` (대상 모듈)
2. **Simulation 상단 모듈**: `plift_core_tb` 선택
3. **`phase2_tb.v` 사용 시** (`$readmemh` 경로 필요):  
   Project Settings → Simulation → **Simulation working directory**  
   → `Z:\2026 CAU\SpikeSense-Edge\git\SpikeSense-Edge` 로 변경
4. Flow Navigator → **Run Simulation → Run Behavioral Simulation**
5. Tcl Console: `run all` 입력 → $display 출력 확인  
   파형: Objects 패널에서 신호를 Waveform 창으로 드래그

---

## 학습된 모델

| 파일 | 데이터셋 | 비고 |
|------|----------|------|
| `best_model_mimii_v2-1.pth` | MIMII | **최고 성능, 권장** |
| `best_model_mimii_v1-1.pth` | MIMII | v1 |
| `best_model_dcase_v2-1.pth` | DCASE | |
| `best_model_dcase_v1-1.pth` | DCASE | |

---

## 개발 현황

### ✅ 완료

- [x] PLIF-T SNN 모델 설계 (`snn_model.py`)
- [x] 학습 루프 구현 — Focal Loss, Mixup, SpecAugment, Resume (`train.py`)
- [x] NumPy 순전파 검증 스크립트 (`test_model_numpy.py`)
- [x] MIMII / DCASE 데이터셋 학습 완료 (모델 4종)
- [x] 1세대 구 RTL (Level Crossing + LIF) 설계 — 신규 시분할 설계로 대체되어 제거

---

### 🔧 진행 중 — 신규 RTL (Mel Spectrogram + PLIF-T)

**Phase 0 — 디렉토리 준비**
- [x] `hardware/src/` 폴더 생성

**Phase 1 — 가중치·파라미터 추출**
- [x] `export_weights.py` — `best_model_mimii_v2-1.pth` → INT8 양자화
- [x] W1/W2/W3/β/V_th를 `$readmemh` 호환 hex 파일로 출력 (`hardware/src/weights/`)
- [x] `test_model_numpy.py` 수정 — INT8 가중치 기반 골든 벡터 저장

**Phase 2 — 핵심 연산 모듈** ✅ 완료
- [x] `plift_core.v` — PLIF-T 뉴런 (β·V_th 파라미터 입력, soft reset)
- [x] `mac_unit.v` — INT8×INT8→INT16 누적, 팬인 가변 (40/128/32)
- [x] `weight_bram.v` — 9,280×8bit BRAM 가중치 저장
- [x] `param_rom.v` — β(162개) + V_th(162개) INT8 ROM
- [x] `membrane_mem.v` — 162뉴런 막전위 16-bit BRAM
- [x] `spike_mem.v` — 레이어별 스파이크 임시 저장 (L1: 128bit, L2: 32bit)
- [x] 테스트벤치 — `plift_core_tb.v` / `mac_unit_tb.v` / `phase2_tb.v` (32 TC 전체 통과)

**Phase 3 — 제어·통합 모듈** ✅ 완료
- [x] `control_fsm.v` — 3레이어 시퀀서 FSM (L1×128 → L2×32 → L3×2, 31 타임스텝)
- [x] `anomaly_judge.v` — Leaky Counter 이상 판정 (1세대 설계 기반)
- [x] `snn_top.v` — 최상위 통합 (`mel_in[40×8bit]` + `frame_valid` → `anomaly_flag`)
- [x] 테스트벤치 — `phase3_tb.v` (57 TC 전체 통과)

**Phase 4 — 검증 및 마무리** ✅ 완료
- [x] `plift_core_tb.v` — PLIF-T 뉴런 단독 (12 TC)
- [x] `tb_snn_top.v` — 골든 벡터 기반 전체 시뮬레이션 (312 TC)
  - Normal/Anomaly 각 31 타임스텝 × L3 막전위·스파이크·anomaly_flag bit-exact 일치

**Phase 5 — 듀얼채널 RTL + SPI 인터페이스** ✅ 완료
- [x] `spi_slave.v` — SPI 수신기 (CPOL=0, CPHA=0, 41바이트 패킷 디코더, 2단 CDC 동기화)
- [x] `dual_snn_top.v` — 2채널 최상위 (spi_slave + snn_top ×2 + channel_id 디먹스)
- [x] `hardware/constraints/nexys_a7_dual.xdc` — Nexys A7 100T 핀 할당 (SPI=Pmod JA, LED0/1)
- [x] `testbench/tb_dual_snn_top.v` — SPI mode 0 마스터 모사, ch0=anomaly·ch1=normal 골든 (314 TC 전체 통과)

**Phase 6-1 — Vivado 합성 및 FPGA 구현 (듀얼채널)** ✅ 완료
- [x] Vivado 프로젝트 자동화 ([hardware/fpga/create_project.tcl](hardware/fpga/create_project.tcl), Top `dual_snn_top`, xc7a100tcsg324-1)
  - ⚠️ 프로젝트 경로는 **ASCII 필수** — 한글 경로면 합성 run(별도 프로세스)이 무에러 크래시
  - hex 경로: `ifdef SYNTHESIS` + PRE 훅([copy_hex.tcl](hardware/fpga/copy_hex.tcl))으로 합성 cwd에 복사
- [x] 합성·구현·비트스트림 동작 확인 — 자원: **LUT 3,211 / FF 7,094 / BRAM36 4 / DSP 2** (각 <6%)
- [x] 타이밍 분석: WNS −5.498ns @100MHz (임계경로 param_rom→PLIF→막전위) → 해결책으로 Phase 6-2 시분할 @50MHz 채택

**Phase 6-2 — 다중 트랙 시분할(TDM) @50MHz** ✅ 완료
- 단일 데이터패스(MAC·weight BRAM·param ROM·spike_mem)를 **N_TRACKS개 트랙이 시분할 공유**, 트랙별 상태(막전위·이상카운터)만 복제. 50MHz에서 임계경로 15.3ns < 20ns 여유. (복제 ~30트랙 한계 대비, 시분할 ~165트랙@50MHz)
- [x] `membrane_mem_mult.v` — 트랙당 256스트라이드 BRAM, 동기읽기 (first_ts 마스킹으로 버퍼리셋)
- [x] `anomaly_judge_mult.v` — 트랙별 Leaky Counter
- [x] `control_fsm_mult.v` — track_id·트랙별 ts 카운터·first_ts (snn_top/dual_snn_top 동결, 신규)
- [x] `mult_snn_top.v` — 시분할 SNN 엔진, `clk_div2.v` — 100→50MHz 2분주
- [x] `mult_spi_top.v` — 보드 최상위 (clk분주 + spi_slave + channel_id=track_id 디먹스 → LED[0..15])
- [x] `tb_mult_snn_top.v` (496 TC, 4트랙 인터리빙 bit-exact) / `tb_mult_spi_top.v` (8 TC, SPI 통합)
- [x] Vivado 자동화 ([create_project_mult.tcl](hardware/fpga/create_project_mult.tcl), Top `mult_spi_top`) + [nexys_a7_mult.xdc](hardware/constraints/nexys_a7_mult.xdc) (50MHz 생성클럭)
- [x] **50MHz 합성·구현·비트스트림 완주** (Vivado 2025.2): **WNS +4.072ns**(타이밍 닫힘), **LUT 2,033 / FF 4,605 / BRAM36 12 / DSP 1** (듀얼 대비 LUT·FF·DSP↓, 막전위 BRAM↑). 0 Warnings.
- [x] **보드 자가진단** — [mult_selftest_top.v](hardware/src/mult_selftest_top.v) + [create_project_selftest.tcl](hardware/fpga/create_project_selftest.tcl): RPi 없이 칩 안 골든 anomaly로 출력 스파이크 62개 자체 비교 → **실제 보드 PASS (LED15 점등)**. iverilog [tb_mult_selftest.v](hardware/testbench/tb_mult_selftest.v)로도 PASS 확인. `mult_snn_top`에 관찰용 `dbg_*` 출력 추가(mult_spi_top 미연결).

**Phase 7 — RPi5 소프트웨어** ✅ 완료
> ⚠️ 시분할 다중트랙이므로 SPI 패킷 첫 바이트에 **track_id(0~N-1)** 를 실어야 함 (포맷 41B 동일, 기존 2채널 0/1 → N트랙 확장).
> ⚠️ 현재 RTL은 **수신 전용(MOSI)** — MISO 리드백 경로 없음. 이상 판정은 보드 LED[track]로만 관찰되며, RPi 터미널 표시는 `--monitor`(numpy 그림자 추론)로 제공.
- [x] `rpi/capture_mel.py` — USB 마이크 N트랙 캡처 + Mel INT8 변환 (학습 `extract_mel_spectrogram`과 1:1 동일 전처리, `MicCapture`/`wav_to_segments`)
- [x] `rpi/fpga_spi.py` — SPI 드라이버 (spidev, 5MHz, mode 0, 41B 패킷 `[track_id][mel×40]`, 프레임 간격 1ms, `MockSpi` 더미 포함)
- [x] `rpi/snn_infer.py` — NumPy INT8 추론 (hex 가중치 로드, **골든 벡터 RTL bit-exact PASS** — PyTorch 불필요)
- [x] `rpi/main.py` — 다중 트랙 실시간 파이프라인 (FPGA 모드 + `--monitor` numpy 그림자, `--dry-run`, `--from-wav`, `--list-mics`)
- [x] `--dry-run` 모드 — FPGA 없이 numpy 추론으로 전 파이프라인 검증 (골든/ WAV / 마이크 입력)

**Phase 8 — 하드웨어 통합 테스트** 🔧 도구 완성 (실보드 점등 확인 대기)
> 마이크/모델 정확도와 **SPI 링크 검증을 분리**: HW 이상판정은 막전위가 아니라 **L3 스파이크 Leaky Counter(`cnt_a>cnt_n`)** 이므로, 그 조건을 확실히 만드는 전용 벡터로 LED를 검증한다. (골든 벡터는 둘 다 LED를 못 켬 — 검증으로 확인)
- [x] `software/make_hw_test_vectors.py` — `hw_anomaly_mel.npy`(cnt_a=31,cnt_n=0→LED ON) / `hw_normal_mel.npy`(cnt_n=29,cnt_a=2→LED OFF) 생성
- [x] `rpi/hw_test.py` — SPI 통합 테스트 (`wiring`/`led`/`sweep`), mock 동작 확인
- [x] **프로토콜 정합성 적대 검증** (멀티에이전트): 패킷 바이트순서·track→LED 매핑·LED 점등논리 PASS. SPI 속도 **10→5MHz**(검증 tb 일치, 마진 확보), 프레임 간격 **500µs→1ms**(busy-drop 방지) 반영
- [ ] (보드) `hw_test.py wiring` → 로직애널라이저로 SCK/MOSI/CS_n 확인
- [ ] (보드) `hw_test.py led` → LED1 ON / LED0 OFF 점등 확인 (SPI 링크·디먹스·이상판정 PASS)
- [ ] (보드) `hw_test.py sweep` → 트랙별 LED 순차 점등 (디먹스 격리)
- [ ] (보드) 실제 팬 소음 정확도 — ⚠️ 모델은 학습 데이터셋(MIMII) 도메인 한정. 타깃 기계 재학습 필요

> **테스트 절차**: ① FPGA에 `mult_spi_top` 비트스트림 프로그램 ② 배선(JA1=SCK/JA2=MOSI/JA3=CS_n/GND) ③ `CPU_RESETN`(C12) 눌러 카운터 초기화 ④ RPi `cd rpi && python3 hw_test.py led` → LED 관찰.

**Phase 9 — 데모** ⬜ 예정
- [ ] `rpi/demo.py` — 터미널 UI (2채널 실시간 상태 표시)
- [ ] 데모 시연 (이상음 재생 → LED + 터미널 동시 반응 확인)

---

## 참고 자료

- [MIMII Dataset](https://zenodo.org/record/3384388) — Malfunctioning Industrial Machine Investigation and Inspection
- [DCASE 2020 Task 2](https://dcase.community/challenge2020/task2-unsupervised-detection-of-anomalous-sounds) — Unsupervised Detection of Anomalous Sounds
- [Parametric LIF (PLIF)](https://arxiv.org/abs/2011.09226) — Incorporating Learnable Membrane Time Constant to Enhance Learning of SNNs
