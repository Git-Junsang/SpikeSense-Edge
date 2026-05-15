"""
SNN 모델 동작 검증 (NumPy 버전)
================================
PyTorch 없이 순전파 로직이 올바른지 확인하는 스크립트입니다.
실제 학습에는 snn_model.py (PyTorch 버전)를 사용하세요.
"""

import numpy as np

# ============================================================
# LIF 뉴런 순전파 (NumPy)
# ============================================================
def lif_step(input_current, membrane, beta, threshold=1.0):
    """
    LIF 뉴런 한 타임스텝 처리
    
    V[t] = β * V[t-1] + I[t]
    V >= Vth → spike, V -= Vth (Soft Reset)
    """
    # ① 누설 + 적분
    membrane = beta * membrane + input_current
    
    # ② 발화 판정
    spikes = (membrane >= threshold).astype(np.float32)
    
    # ③ Soft Reset
    membrane = membrane - spikes * threshold
    
    return spikes, membrane


# ============================================================
# 전체 SNN 순전파
# ============================================================
def snn_forward(spike_input, W1, W2, beta_hidden, beta_output=0.85):
    """
    10 → 4 → 2 SNN 순전파
    
    Args:
        spike_input: [timesteps, 10] 스파이크 입력
        W1: [10, 4] 입력→은닉 가중치
        W2: [4, 2]  은닉→출력 가중치
        beta_hidden: [4] 은닉 뉴런별 감쇠 계수
        beta_output: 출력 뉴런 감쇠 계수
    """
    n_timesteps = spike_input.shape[0]
    
    # 막전위 초기화
    mem_h = np.zeros(4, dtype=np.float32)   # 은닉층
    mem_o = np.zeros(2, dtype=np.float32)   # 출력층
    
    # 기록용
    hidden_spikes = np.zeros((n_timesteps, 4), dtype=np.float32)
    output_spikes = np.zeros((n_timesteps, 2), dtype=np.float32)
    mem_h_record  = np.zeros((n_timesteps, 4), dtype=np.float32)
    
    for t in range(n_timesteps):
        x = spike_input[t]                           # [10]
        
        # 입력 → 은닉: 행렬곱
        current_h = x @ W1                           # [10] × [10,4] = [4]
        
        # 은닉 LIF 처리
        spk_h, mem_h = lif_step(current_h, mem_h, beta_hidden)
        
        # 은닉 → 출력: 행렬곱
        current_o = spk_h @ W2                       # [4] × [4,2] = [2]
        
        # 출력 LIF 처리
        spk_o, mem_o = lif_step(current_o, mem_o, beta_output)
        
        # 기록
        hidden_spikes[t] = spk_h
        output_spikes[t] = spk_o
        mem_h_record[t]  = mem_h
    
    return output_spikes, hidden_spikes, mem_h_record


# ============================================================
# 테스트 실행
# ============================================================
if __name__ == "__main__":
    np.random.seed(42)
    
    print("=" * 50)
    print("SNN 순전파 검증 (NumPy)")
    print("=" * 50)
    
    # --- 설계 사양 ---
    beta_hidden = np.array([0.70, 0.80, 0.90, 0.95])
    
    # --- 가중치 초기화 (랜덤) ---
    W1 = np.random.randn(10, 4).astype(np.float32) * 0.5
    W2 = np.random.randn(4, 2).astype(np.float32) * 0.5
    
    print(f"\nW1 shape: {W1.shape}  (가중치 {W1.size}개)")
    print(f"W2 shape: {W2.shape}  (가중치 {W2.size}개)")
    print(f"총 가중치: {W1.size + W2.size}개")
    
    # --- 테스트 입력: 100ms = 1600 타임스텝 ---
    n_timesteps = 1600
    # 약 10% 확률로 스파이크 발생하는 랜덤 입력
    test_input = (np.random.rand(n_timesteps, 10) > 0.9).astype(np.float32)
    
    print(f"\n입력: {n_timesteps} 타임스텝 × 10채널")
    print(f"입력 스파이크 총 수: {test_input.sum():.0f}개")
    
    # --- 순전파 실행 ---
    out_spk, hid_spk, mem_rec = snn_forward(
        test_input, W1, W2, beta_hidden
    )
    
    # --- 결과 확인 ---
    print(f"\n--- 은닉층 스파이크 수 ---")
    for i in range(4):
        count = hid_spk[:, i].sum()
        print(f"  H{i} (β={beta_hidden[i]:.2f}): {count:.0f}회")
    
    print(f"\n--- 출력층 스파이크 수 ---")
    labels = ["정상(Out0)", "이상(Out1)"]
    for i in range(2):
        count = out_spk[:, i].sum()
        print(f"  {labels[i]}: {count:.0f}회")
    
    # --- 이상 판정 ---
    normal_count  = out_spk[:, 0].sum()
    anomaly_count = out_spk[:, 1].sum()
    result = "이상" if anomaly_count > normal_count else "정상"
    print(f"\n판정: {result} (정상={normal_count:.0f}, 이상={anomaly_count:.0f})")
    
    # --- β에 따른 막전위 변화 비교 ---
    print(f"\n--- β별 막전위 특성 (처음 20 타임스텝) ---")
    print(f"{'t':>3}  {'H0(0.70)':>9}  {'H1(0.80)':>9}  {'H2(0.90)':>9}  {'H3(0.95)':>9}")
    for t in range(20):
        vals = [f"{mem_rec[t, i]:+.4f}" for i in range(4)]
        print(f"{t:3d}  {'  '.join(vals)}")
    
    print("\n✅ 순전파 동작 정상")
    print("\n참고: 가중치가 랜덤이므로 결과는 의미 없습니다.")
    print("      학습 후에야 정상/이상 판별이 가능합니다.")
