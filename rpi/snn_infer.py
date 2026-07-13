"""snn_infer.py — NumPy INT8 SNN 추론 (--dry-run 전용, Phase 7)

FPGA 없이 RPi에서 PLIF-T 순전파(40→128→32→2)를 RTL과 동일한 정수 연산으로 수행한다.
software/test_model_numpy.py 의 검증된 로직과 1:1 동일하되, rpi/ 단독 실행이 가능하도록
hex 가중치만 의존한다 (PyTorch 불필요).

가중치/파라미터: hardware/src/weights/ (export_weights.py 산출물)
  w1.hex(128×40) w2.hex(32×128) w3.hex(2×32)  — INT8
  beta.hex(162)  — uint8 Q0.8 ,  vth.hex(162) — int8 ,  scales.json(l1_shift 등)
"""
import os
import json
import numpy as np

# rpi/ 기준 기본 가중치 경로
_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WEIGHTS = os.path.normpath(os.path.join(_HERE, "..", "hardware", "src", "weights"))


# hex 로더

def _load_hex(path, dtype_uint, dtype_out, shape):
    with open(path) as f:
        vals = [int(v, 16) for v in f.read().split() if v]
    return np.array(vals, dtype=dtype_uint).astype(dtype_out).reshape(shape)


# PLIF-T 한 스텝 (RTL 정수 연산과 1:1)

def _plif_step(current, membrane, beta_q, vth_q):
    decayed = (beta_q.astype(np.int32) * membrane.astype(np.int32)) >> 8
    mem_new = decayed + current.astype(np.int32)
    spikes  = (mem_new >= vth_q.astype(np.int32)).astype(np.int8)
    mem_out = mem_new - spikes.astype(np.int32) * vth_q.astype(np.int32)
    return spikes, np.clip(mem_out, -32768, 32767).astype(np.int16)


class SnnInfer:
    """hex 가중치를 한 번 로드해두고 세그먼트마다 추론한다 (스테이트리스: 세그먼트 단위 reset)."""

    def __init__(self, weights_dir=DEFAULT_WEIGHTS):
        self.W1 = _load_hex(os.path.join(weights_dir, "w1.hex"), np.uint8, np.int8, (128, 40))
        self.W2 = _load_hex(os.path.join(weights_dir, "w2.hex"), np.uint8, np.int8, (32, 128))
        self.W3 = _load_hex(os.path.join(weights_dir, "w3.hex"), np.uint8, np.int8, (2, 32))

        beta = _load_hex(os.path.join(weights_dir, "beta.hex"), np.uint8, np.uint8, (162,))
        self.beta_L1, self.beta_L2, self.beta_L3 = beta[:128], beta[128:160], beta[160:]

        with open(os.path.join(weights_dir, "scales.json")) as f:
            scales = json.load(f)
        self.l1_shift = int(scales.get("l1_shift", 7))
        vth_dt = np.int16 if scales.get("vth_format") == "int16" else np.int8
        vth_ut = np.uint16 if vth_dt is np.int16 else np.uint8
        vth = _load_hex(os.path.join(weights_dir, "vth.hex"), vth_ut, vth_dt, (162,))
        self.vth_L1, self.vth_L2, self.vth_L3 = vth[:128], vth[128:160], vth[160:]

    def forward(self, mel_int8):
        """mel_int8 [T,40] → (mem_L3 [T,2], spk_L3 [T,2]). 막전위는 세그먼트 시작 시 0."""
        T = mel_int8.shape[0]
        mem_L1 = np.zeros(128, np.int16)
        mem_L2 = np.zeros(32,  np.int16)
        mem_L3 = np.zeros(2,   np.int16)
        mem_L3_r = np.zeros((T, 2), np.int16)
        spk_L3_r = np.zeros((T, 2), np.int8)

        W1T = self.W1.T.astype(np.int32)
        W2T = self.W2.T.astype(np.int16)
        W3T = self.W3.T.astype(np.int16)

        for t in range(T):
            mac1 = (mel_int8[t].astype(np.int32) @ W1T) >> self.l1_shift
            spk1, mem_L1 = _plif_step(mac1.astype(np.int16), mem_L1, self.beta_L1, self.vth_L1)
            mac2 = spk1.astype(np.int16) @ W2T
            spk2, mem_L2 = _plif_step(mac2, mem_L2, self.beta_L2, self.vth_L2)
            mac3 = spk2.astype(np.int16) @ W3T
            spk3, mem_L3 = _plif_step(mac3, mem_L3, self.beta_L3, self.vth_L3)
            mem_L3_r[t] = mem_L3
            spk_L3_r[t] = spk3
        return mem_L3_r, spk_L3_r

    def predict(self, mel_int8):
        """세그먼트 1장 → (label 0/1, mem_mean[2]). 막전위 평균 argmax (snn_model.py와 동일 기준)."""
        mem_L3_r, _ = self.forward(mel_int8)
        mem_mean = mem_L3_r.mean(axis=0)
        return int(np.argmax(mem_mean)), mem_mean


class LeakyJudge:
    """FPGA anomaly_judge_mult와 동일한 트랙별 Leaky Counter 섀도우.

    HW 규칙: cnt = cnt - (cnt >> SHIFT_N) + spike  (타임스텝마다),
             LED(anomaly_flag) = (cnt_a > cnt_n).
    전역(버퍼 경계 무관) 누적이라, 보드 CPU_RESETN 직후 main을 시작하면 보드 LED와 정렬된다.
    """

    def __init__(self, shift_n=14):
        self.shift_n = shift_n
        self.cnt_n = 0
        self.cnt_a = 0

    def update(self, spk_L3):
        """spk_L3 [T,2] (n0=정상, n1=이상)을 타임스텝 순서로 누적."""
        for t in range(spk_L3.shape[0]):
            self.cnt_n += int(spk_L3[t, 0]) - (self.cnt_n >> self.shift_n)
            self.cnt_a += int(spk_L3[t, 1]) - (self.cnt_a >> self.shift_n)

    @property
    def led(self):
        return self.cnt_a > self.cnt_n


if __name__ == "__main__":
    # 골든 벡터로 RTL bit-exact 자체 점검 (라벨이 아니라 막전위/스파이크 일치 여부)
    infer = SnnInfer()
    gdir = os.path.join(DEFAULT_WEIGHTS, "golden")
    for tag in ["normal", "anomaly"]:
        mel = np.load(os.path.join(gdir, f"{tag}_mel.npy")).astype(np.int8)
        mem, spk = infer.forward(mel)
        mem_exp = np.load(os.path.join(gdir, f"{tag}_mem_out.npy"))
        spk_exp = np.load(os.path.join(gdir, f"{tag}_spk_out.npy"))
        bit_exact = np.array_equal(mem, mem_exp) and np.array_equal(spk, spk_exp)
        label = int(np.argmax(mem.mean(axis=0)))
        print(f"  {tag:7s} → label={label}  RTL bit-exact={'PASS' if bit_exact else 'FAIL'}")
