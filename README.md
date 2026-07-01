# SpikeSense-Edge

**English** | [한국어](README.ko.md)

**FPGA edge-based SNN acoustic anomaly detection system**

Detects abnormal sounds from fans and machinery in real time at the edge, without the cloud.
The goal is to port a PLIF-T SNN model trained in PyTorch onto a Xilinx Artix-7 FPGA.

---

## System Overview

```
[USB microphones ×2]
   │ 16kHz PCM (independent channels)
   ▼
[Raspberry Pi 5]
   ├─ CH0: Mel Spectrogram → INT8 × 40ch
   └─ CH1: Mel Spectrogram → INT8 × 40ch
   │ SPI (5MHz, 41-byte packet/frame)
   ▼
[Nexys A7 100T FPGA]
   ├─ SPI slave → dual_snn_top
   │    ├─ snn_top #0 (CH0) → LED0
   │    └─ snn_top #1 (CH1) → LED1
   ▼
anomaly_flag × 2 (0=normal / 1=anomaly)
```

| Component               | Role                                                            |
| ----------------------- | -------------------------------------------------------------- |
| Raspberry Pi 5          | 2-channel audio capture, Mel Spectrogram preprocessing, SPI TX |
| Nexys A7 100T (Artix-7) | PLIF-T SNN inference acceleration (2 independent channels)     |

---

## Model Architecture

**PLIF-T SNN (Parametric LIF with Learnable Threshold)**

```
Input (40) → Hidden1 (128) → Hidden2 (32) → Output (2)
              PLIF-T          PLIF-T         PLIF-T
```

- Input: ~1s audio buffer (31 × 32ms = 992ms) → 40-channel Log-Mel Spectrogram → 31 timesteps
- Neuron: both β (decay) and V_th (firing threshold) are learnable parameters
- Classification: argmax of the per-timestep mean membrane potential → normal (0) / anomaly (1)
- Total weights: 9,280 (INT8-quantized in hardware)

### Training Setup

| Item          | Value                                                    |
| ------------- | -------------------------------------------------------- |
| Loss          | Focal Loss (γ=2, class-frequency weighting)             |
| Optimizer     | Adam (lr=0.002, weight_decay=1e-5)                       |
| Scheduler     | Cosine Annealing                                         |
| Augmentation  | SpecAugment (freq/time masking 15%), Mixup (α=0.2)      |
| Features      | 40-mel, FFT=1024, hop=512, 16kHz                         |

---

## Directory Structure

```
SpikeSense-Edge/
├── software/
│   ├── snn_model.py            # PLIF-T SNN model definition (PyTorch)
│   ├── train.py                # Training loop (Focal Loss, Mixup, Resume)
│   ├── test_model_numpy.py     # NumPy forward-pass check (no PyTorch needed)
│   ├── export_weights.py       # INT8 weight extraction → hex files
│   ├── best_model_mimii_v2-1.pth  # Best model (MIMII dataset)
│   ├── data_dcase/             # Full training data (DCASE — normal/, anomaly/)
│   └── data_mimii/             # Lightweight validation data (MIMII)
│
├── hardware/
│   ├── src/                    # New RTL — Mel + PLIF-T (Phase 4 done)
│   │   └── weights/            # INT8 weight hex + golden vectors
│   ├── constraints/            # Vivado XDC pin constraints (Phase 5~6)
│   ├── fpga/                   # Vivado project automation tcl
│   ├── testbench/              # Testbench .v sources
│   └── sim/                    # Compiled outputs (.gitignore)
│
└── rpi/                        # RPi5 software (Phase 7~9 done)
    ├── requirements.txt        # numpy, scipy, soundfile, sounddevice, spidev, luma.oled
    ├── capture_mel.py          # USB mic capture + Mel INT8 (pure numpy, sounddevice/arecord)
    ├── snn_infer.py            # NumPy INT8 inference (dry-run, RTL bit-exact)
    ├── fpga_spi.py             # SPI driver (5MHz, 41B packet, track_id, frame gap)
    ├── main.py                 # Main loop (multi-track pipeline, --dry-run)
    ├── hw_test.py              # Phase 8 SPI integration test (wiring/led/sweep)
    ├── oled_display.py         # 1.3" I2C OLED(SH1106) normal/anomaly display (demo)
    └── demo.py                 # On-board 2-track demo (Enter-stepped, OLED+LED)
```

---

## Getting Started

### Requirements

```bash
pip install torch numpy librosa soundfile scikit-learn
```

### Data Preparation

```
data_dcase/
├── normal/     # Normal-operation WAV files (16kHz recommended)
└── anomaly/    # Abnormal-operation WAV files
```

Supported datasets: [MIMII Dataset](https://zenodo.org/record/3384388), [DCASE 2020 Task 2](https://dcase.community/challenge2020/task2-unsupervised-detection-of-anomalous-sounds)

### Training

```bash
cd software

# Train from scratch
python train.py --data_dir data_dcase --model_name my_model.pth --epochs 150 --batch_size 256

# Continue training (epochs is the final target, not an increment)
python train.py --data_dir data_dcase --model_name my_model.pth --epochs 300 --resume
```

| Option           | Description                                                    | Default            |
| ---------------- | ------------------------------------------------------------- | ------------------ |
| `--data_dir`   | Top-level data folder (must contain normal/, anomaly/)         | required           |
| `--model_name` | Filename of the weights to save/load                          | `best_model.pth` |
| `--epochs`     | Final target epoch count                                       | 150                |
| `--resume`     | Resume epoch/LR/weights from a checkpoint                      | False              |
| `--batch_size` | Batch size                                                     | 256                |
| `--lr`         | Initial learning rate (Cosine Annealing applied)              | 0.002              |
| `--n_mels`     | Number of Mel bands and input channels                        | 40                 |
| `--segment_ms` | Segmentation unit (ms)                                         | 992                |

### Forward-Pass Check (without PyTorch)

```bash
cd software
python test_model_numpy.py
```

---

## Hardware (FPGA RTL)

> **Current status**: **Phase 6 done** — the 100MHz timing miss (WNS −5.498ns) was solved with **multi-track time-division multiplexing (TDM) @50MHz**.<br>
> A single datapath is shared across N tracks (only per-track membrane potential and anomaly counter are replicated). 50MHz synthesis/implementation/bitstream completed → **WNS +4.07ns (timing closed)**, LUT 2,007 · FF 4,605 · BRAM36 12 · DSP 1.<br>
> Verification: iverilog (tb_mult_snn_top 496/496, tb_mult_spi_top 8/8, tb_mult_selftest PASS) + **on-board self-test (mult_selftest_top) silicon PASS** — LED15 lights up with golden input, no RPi required.<br>
> ⚠️ The Vivado project path **must be ASCII** (a Korean path crashes the synthesis run). Vivado power analysis (routed) **0.124W** (dynamic 0.026 + static 0.098).<br>
> **Phase 7·8 done** — RPi5 SW (pure-numpy Mel · energy gate · SPI) + **on-board SPI integration verified** (10-channel sweep lighting · track isolation, live-mic inference LED lighting).<br>
> ⚠️ **Known limitation**: the model is limited to the MIMII/DCASE domain → live arbitrary sound skews toward "normal" (domain mismatch). The HW pipeline itself is fine. **Phase 9: demo with the current model in a quiet environment (re-recording/re-training deferred)**.

### RTL Design Spec (`hardware/src/`)

| Item             | Spec                                                                                              |
| ---------------- | ------------------------------------------------------------------------------------------------ |
| Target board     | Nexys A7 100T (XC7A100T)                                                                          |
| Input interface  | SPI slave (5MHz, 41-byte packet)                                                                  |
| Clock            | 50 MHz (board 100MHz E3 → `clk_div2` divide-by-2)                                               |
| Channels/tracks  | Multi-track TDM (`N_TRACKS`, default 64) — shared single datapath. Initial dual-channel (snn_top×2) is frozen |
| Processing       | Time-multiplexing — 162 neurons/timestep, ≈9,607 clocks/timestep                                |
| Weight storage   | BRAM (9,280 × INT8 ≈ 74Kbits, shared across all tracks)                                         |
| Membrane format  | 16-bit signed, Soft Reset (per-track BRAM)                                                        |
| Anomaly decision | Per-track Leaky Counter (`cnt_anomaly > cnt_normal`)                                            |
| Output           | `anomaly_flags[N]` → LED. LED15=PASS during board self-test                                     |

### Simulation (Testbench)

#### Testbench files (`hardware/testbench/`)

| File                   | Target module                                                                          | # TC      | External files needed    |
| ---------------------- | -------------------------------------------------------------------------------------- | --------- | ------------------------ |
| `plift_core_tb.v`    | PLIF-T neuron standalone                                                                | 12        | none                     |
| `mac_unit_tb.v`      | MAC standalone                                                                          | —        | none                     |
| `phase2_tb.v`        | Phase 2 core modules (6)                                                                | 32        | `weights/*.hex`        |
| `phase3_tb.v`        | Phase 3 control_fsm · snn_top                                                          | 57        | `weights/*.hex`        |
| `tb_snn_top.v`       | Full-system golden-vector verification                                                  | 312       | `weights/golden/*.hex` |
| `tb_dual_snn_top.v`  | Dual-channel + SPI (mode 0) verification                                                | 314       | `weights/golden/*.hex` |
| `tb_mult_snn_top.v`  | Multi-track TDM core (4-track interleaved golden)                                       | 496       | `weights/golden/*.hex` |
| `tb_mult_spi_top.v`  | SPI-integrated TDM (clk divider + track demux)                                          | 8         | `weights/golden/*.hex` |
| `tb_mult_selftest.v` | Board self-test (mult_selftest_top) sim — self-compares 62 golden spikes → LED15=PASS | PASS/FAIL | `weights/golden/*.hex` |

#### A. VSCode terminal (iverilog)

```bash
mkdir -p hardware/sim

# Standalone modules — no external files, run immediately
/usr/bin/iverilog -g2001 -o hardware/sim/plift_core_tb \
    hardware/testbench/plift_core_tb.v hardware/src/plift_core.v
/usr/bin/vvp hardware/sim/plift_core_tb

/usr/bin/iverilog -g2001 -o hardware/sim/mac_unit_tb \
    hardware/testbench/mac_unit_tb.v hardware/src/mac_unit.v
/usr/bin/vvp hardware/sim/mac_unit_tb

# Phase 2 (needs weights/ hex files)
/usr/bin/iverilog -g2001 -o hardware/sim/phase2_tb \
    hardware/testbench/phase2_tb.v hardware/src/*.v
/usr/bin/vvp hardware/sim/phase2_tb

# Phase 3
/usr/bin/iverilog -g2001 -o hardware/sim/phase3_tb \
    hardware/testbench/phase3_tb.v hardware/src/*.v
/usr/bin/vvp hardware/sim/phase3_tb

# Phase 4 — full-system golden-vector verification
/usr/bin/iverilog -g2001 -o hardware/sim/snn_top \
    hardware/testbench/tb_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/snn_top

# Phase 5 — dual-channel + SPI interface verification
/usr/bin/iverilog -g2001 -o hardware/sim/dual_snn_top \
    hardware/testbench/tb_dual_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/dual_snn_top

# Phase 6-2 — multi-track TDM (50MHz): core golden verification
/usr/bin/iverilog -g2001 -o hardware/sim/mult_snn_top \
    hardware/testbench/tb_mult_snn_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_snn_top
# Phase 6-2 — SPI-integrated (clk divider + track demux) verification
/usr/bin/iverilog -g2001 -o hardware/sim/mult_spi_top \
    hardware/testbench/tb_mult_spi_top.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_spi_top

# Phase 6-2 — board self-test (mult_selftest_top) sim (LED15=PASS, no RPi)
/usr/bin/iverilog -g2001 -o hardware/sim/mult_selftest \
    hardware/testbench/tb_mult_selftest.v hardware/src/*.v
/usr/bin/vvp hardware/sim/mult_selftest
```

#### B. Vivado (Windows / SMB Z:/ mount)

> The server's `/data` folder must be mounted as `Z:/` on Windows.

1. **Add sources**: Sources → Add Sources → Simulation
   - `Z:\...\SpikeSense-Edge\hardware\testbench\plift_core_tb.v`
   - `Z:\...\SpikeSense-Edge\hardware\src\plift_core.v` (target module)
2. **Simulation top module**: select `plift_core_tb`
3. **When using `phase2_tb.v`** (needs the `$readmemh` path): Project Settings → Simulation → **Simulation working directory** → change to `Z:\2026 CAU\SpikeSense-Edge\git\SpikeSense-Edge`
4. Flow Navigator → **Run Simulation → Run Behavioral Simulation**
5. Tcl Console: type `run all` → check $display output. Waveform: drag signals from the Objects panel into the Waveform window

---

## Trained Models

| File                          | Dataset | Note                |
| ----------------------------- | ------- | ------------------- |
| `best_model_mimii_v2-1.pth` | MIMII   | **Best, recommended** |
| `best_model_mimii_v1-1.pth` | MIMII   | v1                  |
| `best_model_dcase_v2-1.pth` | DCASE   |                     |
| `best_model_dcase_v1-1.pth` | DCASE   |                     |

---

## Development Status

### ✅ Done

- [X] PLIF-T SNN model design (`snn_model.py`)
- [X] Training loop — Focal Loss, Mixup, SpecAugment, Resume (`train.py`)
- [X] NumPy forward-pass verification script (`test_model_numpy.py`)
- [X] MIMII / DCASE dataset training complete (4 models)
- [X] 1st-gen legacy RTL (Level Crossing + LIF) — removed, replaced by the new TDM design

---

### 🔧 New RTL (Mel Spectrogram + PLIF-T)

**Phase 0 — directory setup**

- [X] Created `hardware/src/`

**Phase 1 — weight/parameter export**

- [X] `export_weights.py` — `best_model_mimii_v2-1.pth` → INT8 quantization
- [X] W1/W2/W3/β/V_th exported as `$readmemh`-compatible hex files (`hardware/src/weights/`)
- [X] `test_model_numpy.py` updated — saves INT8-weight-based golden vectors

**Phase 2 — core compute modules** ✅ done

- [X] `plift_core.v` — PLIF-T neuron (β·V_th parameter input, soft reset)
- [X] `mac_unit.v` — INT8×INT8→INT16 accumulate, variable fan-in (40/128/32)
- [X] `weight_bram.v` — 9,280×8bit BRAM weight storage
- [X] `param_rom.v` — β(162) + V_th(162) INT8 ROM
- [X] `membrane_mem.v` — 162-neuron 16-bit membrane BRAM
- [X] `spike_mem.v` — per-layer spike buffer (L1: 128bit, L2: 32bit)
- [X] Testbenches — `plift_core_tb.v` / `mac_unit_tb.v` / `phase2_tb.v` (all 32 TC pass)

**Phase 3 — control/integration modules** ✅ done

- [X] `control_fsm.v` — 3-layer sequencer FSM (L1×128 → L2×32 → L3×2, 31 timesteps)
- [X] `anomaly_judge.v` — Leaky Counter anomaly decision (based on 1st-gen design)
- [X] `snn_top.v` — top-level integration (`mel_in[40×8bit]` + `frame_valid` → `anomaly_flag`)
- [X] Testbench — `phase3_tb.v` (all 57 TC pass)

**Phase 4 — verification & wrap-up** ✅ done

- [X] `plift_core_tb.v` — PLIF-T neuron standalone (12 TC)
- [X] `tb_snn_top.v` — full golden-vector simulation (312 TC)
  - Normal/Anomaly each 31 timesteps × L3 membrane/spike/anomaly_flag bit-exact match

**Phase 5 — dual-channel RTL + SPI interface** ✅ done

- [X] `spi_slave.v` — SPI receiver (CPOL=0, CPHA=0, 41-byte packet decoder, 2-stage CDC sync)
- [X] `dual_snn_top.v` — 2-channel top (spi_slave + snn_top ×2 + channel_id demux)
- [X] `hardware/constraints/nexys_a7_dual.xdc` — Nexys A7 100T pin assignment (SPI=Pmod JA, LED0/1)
- [X] `testbench/tb_dual_snn_top.v` — SPI mode 0 master emulation, ch0=anomaly · ch1=normal golden (all 314 TC pass)

**Phase 6-1 — Vivado synthesis & FPGA implementation (dual-channel)** ✅ done

- [X] Vivado project automation ([hardware/fpga/create_project.tcl](hardware/fpga/create_project.tcl), Top `dual_snn_top`, xc7a100tcsg324-1)
  - ⚠️ Project path **must be ASCII** — a Korean path crashes the synthesis run (separate process) with no error
  - hex path: `ifdef SYNTHESIS` + PRE hook ([copy_hex.tcl](hardware/fpga/copy_hex.tcl)) copies into the synthesis cwd
- [X] Synthesis/implementation/bitstream verified — resources: **LUT 3,211 / FF 7,094 / BRAM36 4 / DSP 2** (each <6%)
- [X] Timing: WNS −5.498ns @100MHz (critical path param_rom→PLIF→membrane) → solution: adopt Phase 6-2 TDM @50MHz

**Phase 6-2 — multi-track TDM @50MHz** ✅ done

- A single datapath (MAC · weight BRAM · param ROM · spike_mem) is **time-shared across N_TRACKS tracks**, replicating only per-track state (membrane · anomaly counter). At 50MHz the critical path 15.3ns < 20ns has margin. (vs. ~30-track replication limit, TDM reaches ~165 tracks @50MHz)

- [X] `membrane_mem_mult.v` — 256-stride BRAM per track, synchronous read (buffer reset via first_ts masking)
- [X] `anomaly_judge_mult.v` — per-track Leaky Counter
- [X] `control_fsm_mult.v` — track_id · per-track ts counter · first_ts (snn_top/dual_snn_top frozen, new)
- [X] `mult_snn_top.v` — TDM SNN engine, `clk_div2.v` — 100→50MHz divide-by-2
- [X] `mult_spi_top.v` — board top (clk divider + spi_slave + channel_id=track_id demux → LED[0..15])
- [X] `tb_mult_snn_top.v` (496 TC, 4-track interleaved bit-exact) / `tb_mult_spi_top.v` (8 TC, SPI integration)
- [X] Vivado automation ([create_project_mult.tcl](hardware/fpga/create_project_mult.tcl), Top `mult_spi_top`) + [nexys_a7_mult.xdc](hardware/constraints/nexys_a7_mult.xdc) (50MHz generated clock)
- [X] **50MHz synthesis/implementation/bitstream complete** (Vivado 2025.2): **WNS +4.07ns** (timing closed), **LUT 2,007 / FF 4,605 / BRAM36 12 / DSP 1** (post-implementation/placed; vs. dual: LUT·FF·DSP↓, membrane BRAM↑). 0 Warnings.
- [X] **Board self-test** — [mult_selftest_top.v](hardware/src/mult_selftest_top.v) + [create_project_selftest.tcl](hardware/fpga/create_project_selftest.tcl): on-chip golden anomaly self-compares 62 output spikes without RPi → **real board PASS (LED15 on)**. Also PASS via iverilog [tb_mult_selftest.v](hardware/testbench/tb_mult_selftest.v). Added observation `dbg_*` outputs to `mult_snn_top` (unconnected in mult_spi_top).

**Phase 7 — RPi5 software** ✅ done

> ⚠️ Since it is multi-track TDM, the first SPI packet byte must carry **track_id(0~N-1)** (41B format unchanged, extending the old 2-channel 0/1 to N tracks).<br>
> ⚠️ The current RTL is **receive-only (MOSI)** — no MISO readback path. Anomaly decisions are observed only via the board LED[track]; the RPi terminal display is provided by `--monitor` (numpy shadow inference).

- [X] `rpi/capture_mel.py` — USB-mic N-track capture + Mel INT8 conversion (1:1 identical preprocessing to training `extract_mel_spectrogram`, `MicCapture`/`wav_to_segments`)
- [X] `rpi/fpga_spi.py` — SPI driver (spidev, 5MHz, mode 0, 41B packet `[track_id][mel×40]`, 1ms frame gap, includes `MockSpi` dummy)
- [X] `rpi/snn_infer.py` — NumPy INT8 inference (loads hex weights, **golden-vector RTL bit-exact PASS** — no PyTorch)
- [X] `rpi/main.py` — multi-track real-time pipeline (FPGA mode + `--monitor` numpy shadow, `--dry-run`, `--from-wav`, `--list-mics`)
- [X] `--dry-run` mode — verifies the whole pipeline via numpy inference without an FPGA (golden / WAV / mic input)

**Phase 8 — hardware integration test** ✅ done

> Separate **SPI-link verification** from mic/model accuracy: the HW anomaly decision is not the membrane potential but the **L3-spike Leaky Counter (`cnt_a>cnt_n`)**, so the LED is verified with a dedicated vector that reliably satisfies that condition. (Golden vectors light neither LED — confirmed by verification.)

- [X] `software/make_hw_test_vectors.py` — generates `hw_anomaly_mel.npy` (cnt_a=31, cnt_n=0 → LED ON) / `hw_normal_mel.npy` (cnt_n=29, cnt_a=2 → LED OFF)
- [X] `rpi/hw_test.py` — SPI integration test (`wiring`/`led`/`sweep`), mock operation confirmed
- [X] **Protocol-consistency adversarial verification** (multi-agent): packet byte order · track→LED mapping · LED-lighting logic PASS. SPI speed **10→5MHz** (matches verified tb, adds margin), frame gap **500µs→1ms** (prevents busy-drop) applied
- [X] **(board) `hw_test.py sweep` → per-track LED sequential lighting** = 10-channel simultaneous SPI demux · track isolation demonstrated
- [X] **(board) live-mic inference** (`main.py --alsa`) → LED lights = full mic→Mel→SPI→FPGA→decision path works
- [X] (board) `tb_mult_spi_power.v` — stimulus-only tb for power SAIF (no internal refs/hex → timing netlist can elaborate)

- ⚠️ Real fan-noise accuracy — the model is **domain-limited** to MIMII/DCASE (see limitation below). The HW path is fine. Re-training deferred.

> **Test procedure**: ① program the `mult_spi_top` bitstream to the FPGA ② wiring (JA1=SCK/JA2=MOSI/JA3=CS_n/GND) ③ initialize `CPU_RESETN` (C12) ④ `cd rpi && python3 hw_test.py sweep --tracks 10` → observe LED0–9 lighting in sequence.

**Phase 9 — on-board demo** ✅ implemented (quiet environment, current model as-is)

> ⚠️ **Re-recording/re-training deferred**, demoed with the current MIMII-trained model. In-domain input (MIMII audio playback / `--from-wav`) is recommended to demonstrate normal/anomaly separation. Live arbitrary sound is out of domain, so decisions are unstable ([limitation](#known-limitation--domain-mismatch)).

- [X] Live demo path works — `main.py --alsa plughw:2,0 --monitor` (LED + terminal Leaky Counter prediction together)
- [X] `rpi/demo.py` — on-board 2-track demo (each Enter step sends 2-track SPI + numpy inference)
- [X] `rpi/oled_display.py` — 1.3" I2C OLED(SH1106) normal/anomaly display
- [X] Segment-decision RTL — `anomaly_judge_seg.v` (31-ts majority vote) + `demo_snn_top.v`/`demo_spi_top.v` + `tb_demo_spi_top.v` (user-sequence reproduction PASS 8/0)
- [X] `nexys_a7_demo.xdc` — QSPI flash boot settings (CFGBVS/CONFIG_VOLTAGE, etc.) added

---

## Known Limitation — Domain Mismatch

- **Symptom**: live arbitrary sound is mostly classified "normal", while in a quiet environment normalization gain skews it toward "anomaly" — live decisions are unstable.
- **Cause**: the model learned only *that specific machine sound* from the training dataset (MIMII/DCASE) → the user's environment/mic/background is out of the training distribution (OOD). Per-buffer normalization mismatch (~10%p vs. offline) adds to it.
- **The HW pipeline is fine** — with MIMII anomaly wav input it correctly detects ANOMALY. The limitation is purely a model-domain issue.
- **Fix direction**: (re)training on the target machine is the fundamental solution. Keeping the 40-128-32-2 + 2-output + Leaky Counter structure, adaptation is possible by **swapping only the weights (hex)** (RTL frozen).

---

## References

- [MIMII Dataset](https://zenodo.org/record/3384388) — Malfunctioning Industrial Machine Investigation and Inspection
- [DCASE 2020 Task 2](https://dcase.community/challenge2020/task2-unsupervised-detection-of-anomalous-sounds) — Unsupervised Detection of Anomalous Sounds
- [Parametric LIF (PLIF)](https://arxiv.org/abs/2011.09226) — Incorporating Learnable Membrane Time Constant to Enhance Learning of SNNs
```
