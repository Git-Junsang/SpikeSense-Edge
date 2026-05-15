"""
SNN 기반 1D 음향 이상 감지 모델 (v2)
=====================================
v1 문제: 출력 스파이크가 0이라 기울기 전달 불가 → 학습 안 됨
v2 수정: 출력층 막전위도 반환 → 학습 시에는 막전위로 손실 계산

설계 사양:
  - 네트워크: 10(입력) → 4(은닉) → 2(출력)
  - 뉴런: LIF (Leaky Integrate-and-Fire), Soft Reset
  - 은닉층 β: [0.70, 0.80, 0.90, 0.95]
  - 임계값: Vth = 1.0
  - 역전파: Fast Sigmoid Surrogate Gradient
  - 가중치: 총 48개
"""

import torch
import torch.nn as nn
import numpy as np


# ============================================================
# 1. Surrogate Gradient (대리 기울기)
# ============================================================

class FastSigmoidSurrogate(torch.autograd.Function):
    """
    순전파: 실제 계단 함수 (0 또는 1)
    역전파: Fast Sigmoid 미분으로 기울기 근사
    """

    @staticmethod
    def forward(ctx, membrane, threshold):
        ctx.save_for_backward(membrane, threshold)
        return (membrane >= threshold).float()

    @staticmethod
    def backward(ctx, grad_output):
        membrane, threshold = ctx.saved_tensors
        x = membrane - threshold
        grad = 1.0 / (2.0 * (1.0 + torch.abs(x)) ** 2)
        return grad * grad_output, None


def spike_fn(membrane, threshold):
    return FastSigmoidSurrogate.apply(membrane, threshold)


# ============================================================
# 2. LIF 뉴런 레이어
# ============================================================

class LIFLayer(nn.Module):
    def __init__(self, n_neurons, beta, threshold=1.0):
        super().__init__()
        self.n_neurons = n_neurons
        self.threshold = threshold

        if isinstance(beta, (list, np.ndarray)):
            self.beta = torch.tensor(beta, dtype=torch.float32)
        else:
            self.beta = torch.tensor([beta] * n_neurons, dtype=torch.float32)

        self.thr = torch.tensor(threshold, dtype=torch.float32)

    def forward(self, input_current, membrane):
        beta = self.beta.to(input_current.device)
        thr = self.thr.to(input_current.device)

        # 누설 + 적분
        membrane = beta * membrane + input_current

        # 발화
        spikes = spike_fn(membrane, thr)

        # Soft Reset
        membrane = membrane - spikes * self.threshold

        return spikes, membrane

    def init_membrane(self, batch_size, device='cpu'):
        return torch.zeros(batch_size, self.n_neurons, device=device)

# ============================================================
# 3. SNN 전체 모델
# ============================================================
#
# ★ v2 핵심 변경점 ★
#
#   학습 시 왜 막전위가 필요한가?
#
#   스파이크는 0 또는 1이라서, 출력 뉴런이 스파이크를 못 쏘면
#   Out0=0, Out1=0 → 둘 다 같으니 뭘 고쳐야 할지 모름 → 학습 불가
#
#   막전위는 실수값(예: 0.3, 0.7)이라서,
#   Out0=0.3, Out1=0.7 → "Out1이 더 크네" → 이 차이로 학습 가능
#
#   정리:
#     학습 시: 막전위(연속값)로 손실 계산 → 기울기가 잘 흐름
#     추론 시: 스파이크 수로 판정 → FPGA에서도 이렇게 동작

class AnomalySNN(nn.Module):
    def __init__(self):
        super().__init__()

        self.n_input  = 10
        self.n_hidden = 4
        self.n_output = 2

        # 시냅스 가중치
        self.fc1 = nn.Linear(self.n_input, self.n_hidden, bias=False)
        self.fc2 = nn.Linear(self.n_hidden, self.n_output, bias=False)

        # ★ 가중치 초기화를 더 크게 설정 (스파이크가 잘 발생하도록)
        nn.init.xavier_normal_(self.fc1.weight, gain=5.0)
        nn.init.xavier_normal_(self.fc2.weight, gain=5.0)

        # 은닉층 LIF (다중 β)
        self.hidden_lif = LIFLayer(
            n_neurons=self.n_hidden,
            beta=[0.70, 0.80, 0.90, 0.95],
            threshold=1.0
        )

        # 출력층 LIF
        self.output_lif = LIFLayer(
            n_neurons=self.n_output,
            beta=0.85,
            threshold=1.0
        )

    def forward(self, spike_input):
        """
        Returns:
            output_spikes: [batch, timesteps, 2] 스파이크 (추론용)
            output_mem:    [batch, timesteps, 2] 막전위   (학습용) ★
            hidden_spikes: [batch, timesteps, 4] 은닉 스파이크
        """
        batch_size = spike_input.size(0)
        n_timesteps = spike_input.size(1)
        device = spike_input.device

        mem_hidden = self.hidden_lif.init_membrane(batch_size, device)
        mem_output = self.output_lif.init_membrane(batch_size, device)

        hidden_spike_record = []
        output_spike_record = []
        output_mem_record = []

        for t in range(n_timesteps):
            x = spike_input[:, t, :]

            # 입력 → 은닉
            current_hidden = self.fc1(x)
            spk_hidden, mem_hidden = self.hidden_lif(current_hidden, mem_hidden)

            # 은닉 → 출력
            current_output = self.fc2(spk_hidden)
            spk_output, mem_output = self.output_lif(current_output, mem_output)

            hidden_spike_record.append(spk_hidden)
            output_spike_record.append(spk_output)
            output_mem_record.append(mem_output.clone())  # ★ 막전위 저장

        output_spikes = torch.stack(output_spike_record, dim=1)
        output_mem = torch.stack(output_mem_record, dim=1)
        hidden_spikes = torch.stack(hidden_spike_record, dim=1)

        return output_spikes, output_mem, hidden_spikes

    def predict(self, spike_input, window_ms=100, sample_rate=16000):
        """추론용: 스파이크 수 기반 판정"""
        self.eval()
        with torch.no_grad():
            output_spikes, _, _ = self.forward(spike_input)

        window_size = int(window_ms * sample_rate / 1000)
        window_size = min(window_size, output_spikes.size(1))

        normal_count  = output_spikes[:, -window_size:, 0].sum(dim=1)
        anomaly_count = output_spikes[:, -window_size:, 1].sum(dim=1)

        return (anomaly_count > normal_count).long()

    def count_parameters(self):
        total = sum(p.numel() for p in self.parameters() if p.requires_grad)
        print(f"총 학습 가능 파라미터: {total}개")
        print(f"  W1 (입력→은닉): {self.fc1.weight.numel()}개  ({self.n_input}×{self.n_hidden})")
        print(f"  W2 (은닉→출력): {self.fc2.weight.numel()}개  ({self.n_hidden}×{self.n_output})")
        return total


# ============================================================
# 4. 테스트
# ============================================================
if __name__ == "__main__":
    print("=" * 50)
    print("SNN 모델 v2 확인")
    print("=" * 50)

    model = AnomalySNN()
    model.count_parameters()

    test_input = (torch.rand(2, 1600, 10) > 0.9).float()
    output_spikes, output_mem, hidden_spikes = model(test_input)

    print(f"\n출력 스파이크 shape: {output_spikes.shape}")
    print(f"출력 막전위 shape:  {output_mem.shape}")

    for i in range(2):
        spk = output_spikes[0, :, i].sum().item()
        mem = output_mem[0, :, i].mean().item()
        label = ["정상(Out0)", "이상(Out1)"][i]
        print(f"  {label}: 스파이크 {spk:.0f}회, 평균막전위 {mem:.4f}")
