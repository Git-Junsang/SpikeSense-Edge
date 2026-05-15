"""
SNN 학습 루프 (v3 - 전처리 데이터 캐싱 및 GPU 최적화 적용)
===========================================================
v3 수정:
  - 전처리된 스파이크 데이터를 .pt 파일로 캐싱하여 재시작 시 로딩 속도 1초로 단축
  - DataLoader 멀티코어 최적화 (num_workers, pin_memory) 유지
"""

import os
import argparse
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
from sklearn.metrics import (
    accuracy_score,
    f1_score,
    confusion_matrix,
    classification_report,
)

from snn_model import AnomalySNN


# ============================================================
# 1. 전처리
# ============================================================

def preprocess(filepath):
    """음향 파일 읽기 → DC 제거 → 정규화 (-1~+1)"""
    import soundfile as sf

    data, sr = sf.read(filepath)
    if data.ndim > 1:
        data = data[:, 0]
    data = data - np.mean(data)
    max_val = np.max(np.abs(data))
    if max_val > 0:
        data = data / max_val
    return data.astype(np.float32), sr


# ============================================================
# 2. Level Crossing 인코더
# ============================================================

def level_crossing_encoding(signal, n_levels=5):
    """
    실수 신호 → 스파이크(0/1) 변환. 5레벨 × 2방향 = 10채널
    NumPy 벡터 연산으로 고속 처리
    """
    levels = np.linspace(-1, 1, n_levels + 2)[1:-1]
    n_channels = n_levels * 2
    n_samples = len(signal)
    spike_trains = np.zeros((n_samples, n_channels), dtype=np.float32)

    prev = signal[:-1]  
    curr = signal[1:]   

    for j, level in enumerate(levels):
        up_cross = (prev < level) & (curr >= level)
        spike_trains[1:, j * 2] = up_cross.astype(np.float32)

        down_cross = (prev >= level) & (curr < level)
        spike_trains[1:, j * 2 + 1] = down_cross.astype(np.float32)

    return spike_trains


# ============================================================
# 3. 세그먼트 분할
# ============================================================

def segment_signal(spike_trains, segment_length=16000):
    """인코딩된 스파이크를 고정 길이로 분할"""
    segments = []
    for start in range(0, len(spike_trains) - segment_length + 1, segment_length):
        segments.append(spike_trains[start : start + segment_length])
    return segments


# ============================================================
# 4. Dataset
# ============================================================

class SpikeDataset(Dataset):
    def __init__(self, spike_segments, labels):
        self.data = [torch.tensor(seg, dtype=torch.float32) for seg in spike_segments]
        self.labels = torch.tensor(labels, dtype=torch.long)

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        return self.data[idx], self.labels[idx]


# ============================================================
# 5. 데이터 로딩 (★ 캐싱 기능 추가)
# ============================================================

def load_mimii_data(data_dir, segment_length=16000):
    """MIMII 데이터셋 로드 및 캐싱"""
    # 세그먼트 길이별로 다른 캐시 파일 생성
    cache_file = os.path.join(data_dir, f"mimii_cache_{segment_length}.pt")
    
    # 1. 캐시 파일이 존재하면 즉시 로드
    if os.path.exists(cache_file):
        print(f"  💾 전처리된 캐시 데이터를 불러옵니다: {cache_file}")
        all_segments, all_labels = torch.load(cache_file, weights_only=False)
        return all_segments, all_labels

    # 2. 캐시가 없으면 원본부터 전처리 수행
    print("  ⏳ 캐시 파일이 없습니다. 오디오 전처리를 시작합니다. (최초 1회만 실행됨)")
    all_segments = []
    all_labels = []

    for label_names, label_value in [
        (["normal"], 0),
        (["anomaly", "abnormal"], 1),
    ]:
        folder = None
        for name in label_names:
            candidate = os.path.join(data_dir, name)
            if os.path.exists(candidate):
                folder = candidate
                break
        if folder is None:
            continue
        
        label_name = os.path.basename(folder)
        wav_files = sorted([f for f in os.listdir(folder) if f.endswith(".wav")])
        print(f"  [{label_name}] {len(wav_files)}개 파일 변환 중...")

        for i, fname in enumerate(wav_files):
            signal, sr = preprocess(os.path.join(folder, fname))
            spikes = level_crossing_encoding(signal)
            segs = segment_signal(spikes, segment_length)
            all_segments.extend(segs)
            all_labels.extend([label_value] * len(segs))

            if (i + 1) % 500 == 0 or (i + 1) == len(wav_files):
                print(f"    진행률: {i+1}/{len(wav_files)}")

    # 3. 전처리 결과를 디스크에 저장
    print(f"  💾 전처리 완료. 데이터를 파일로 캐싱합니다: {cache_file}")
    torch.save((all_segments, all_labels), cache_file)

    return all_segments, all_labels


def generate_synthetic_data(n_normal=50, n_anomaly=50, segment_length=8000):
    """합성 데이터 (코드 테스트용)"""
    print("합성 데이터 생성 중...")
    all_segments = []
    all_labels = []
    sr = 16000

    for i in range(n_normal):
        t = np.arange(segment_length) / sr
        freq = np.random.uniform(100, 500)
        signal = 0.5 * np.sin(2 * np.pi * freq * t)
        signal += 0.05 * np.random.randn(segment_length)
        signal = signal / (np.max(np.abs(signal)) + 1e-8)
        spikes = level_crossing_encoding(signal.astype(np.float32))
        all_segments.append(spikes)
        all_labels.append(0)

    for i in range(n_anomaly):
        t = np.arange(segment_length) / sr
        freq = np.random.uniform(100, 500)
        signal = 0.5 * np.sin(2 * np.pi * freq * t)
        signal += 0.15 * np.random.randn(segment_length)
        n_impacts = np.random.randint(3, 10)
        for _ in range(n_impacts):
            pos = np.random.randint(0, segment_length)
            width = np.random.randint(50, 200)
            signal[pos : pos + width] += np.random.uniform(0.3, 0.8)
        signal = signal / (np.max(np.abs(signal)) + 1e-8)
        spikes = level_crossing_encoding(signal.astype(np.float32))
        all_segments.append(spikes)
        all_labels.append(1)

    return all_segments, all_labels


# ============================================================
# 6. 손실 함수
# ============================================================

def membrane_loss(output_mem, targets, loss_fn):
    mem_sum = output_mem.mean(dim=1)
    loss = loss_fn(mem_sum, targets)
    return loss


# ============================================================
# 7. 학습 1 에포크
# ============================================================

def train_one_epoch(model, dataloader, optimizer, loss_fn, device):
    model.train()
    total_loss = 0.0
    all_preds = []
    all_targets = []

    for batch_idx, (spike_input, targets) in enumerate(dataloader):
        spike_input = spike_input.to(device)
        targets = targets.to(device)

        output_spikes, output_mem, _ = model(spike_input)
        loss = membrane_loss(output_mem, targets, loss_fn)

        optimizer.zero_grad()
        loss.backward()
        optimizer.step()

        total_loss += loss.item()

        mem_sum = output_mem.mean(dim=1)
        preds = mem_sum.argmax(dim=1)
        all_preds.extend(preds.cpu().numpy())
        all_targets.extend(targets.cpu().numpy())

        if (batch_idx + 1) % 10 == 0:
            print(f"    배치 {batch_idx+1}/{len(dataloader)}, 손실: {loss.item():.4f}")

    avg_loss = total_loss / len(dataloader)
    accuracy = accuracy_score(all_targets, all_preds)
    return avg_loss, accuracy


# ============================================================
# 8. 평가
# ============================================================

def evaluate(model, dataloader, loss_fn, device):
    model.eval()
    total_loss = 0.0
    all_preds = []
    all_targets = []

    with torch.no_grad():
        for spike_input, targets in dataloader:
            spike_input = spike_input.to(device)
            targets = targets.to(device)

            output_spikes, output_mem, _ = model(spike_input)
            loss = membrane_loss(output_mem, targets, loss_fn)
            total_loss += loss.item()

            mem_sum = output_mem.mean(dim=1)
            preds = mem_sum.argmax(dim=1)
            all_preds.extend(preds.cpu().numpy())
            all_targets.extend(targets.cpu().numpy())

    avg_loss = total_loss / len(dataloader)
    accuracy = accuracy_score(all_targets, all_preds)
    f1 = f1_score(all_targets, all_preds, average="binary", zero_division=0)
    return avg_loss, accuracy, f1, all_preds, all_targets


# ============================================================
# 9. 메인
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="SNN 이상 감지 학습")
    parser.add_argument("--data_dir", type=str, default=None)
    parser.add_argument("--use_synthetic", action="store_true")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch_size", type=int, default=1024) # 기본값 최적화
    parser.add_argument("--lr", type=float, default=5e-3)       # 기본값 최적화
    parser.add_argument("--segment_ms", type=int, default=250)  # 기본값 최적화
    parser.add_argument("--resume", action="store_true",
                        help="best_model.pth에서 이어서 학습")
    args = parser.parse_args()

    sr = 16000
    segment_length = int(args.segment_ms * sr / 1000)

    print("=" * 55)
    print("  SNN 이상 감지 학습 (v3 - 캐싱 적용)")
    print("=" * 55)
    print(f"  세그먼트: {args.segment_ms}ms ({segment_length} 샘플)")
    print(f"  에포크: {args.epochs}, 배치: {args.batch_size}, LR: {args.lr}")

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"  디바이스: {device}")

    # --- 데이터 ---
    if args.use_synthetic or args.data_dir is None:
        segments, labels = generate_synthetic_data(
            n_normal=50, n_anomaly=50, segment_length=segment_length
        )
    else:
        print(f"\n데이터 로드 경로: {args.data_dir}")
        segments, labels = load_mimii_data(args.data_dir, segment_length)

    if len(segments) == 0:
        print("❌ 데이터가 없습니다.")
        return

    n_total = len(segments)
    n_train = int(n_total * 0.8)
    indices = np.random.permutation(n_total)

    train_segments = [segments[i] for i in indices[:n_train]]
    train_labels   = [labels[i] for i in indices[:n_train]]
    test_segments  = [segments[i] for i in indices[n_train:]]
    test_labels    = [labels[i] for i in indices[n_train:]]

    print(f"\n  학습: {len(train_segments)}개 (정상 {train_labels.count(0)}, 이상 {train_labels.count(1)})")
    print(f"  테스트: {len(test_segments)}개 (정상 {test_labels.count(0)}, 이상 {test_labels.count(1)})")

    # DataLoader 병목 해소 최적화 적용
    train_loader = DataLoader(
        SpikeDataset(train_segments, train_labels),
        batch_size=args.batch_size, shuffle=True,
        num_workers=4, pin_memory=True
    )
    test_loader = DataLoader(
        SpikeDataset(test_segments, test_labels),
        batch_size=args.batch_size, shuffle=False,
        num_workers=4, pin_memory=True
    )

    model = AnomalySNN().to(device)
    model.count_parameters()

    if args.resume and os.path.exists("best_model.pth"):
        model.load_state_dict(torch.load("best_model.pth", weights_only=True))
        print("  📂 이전 모델(best_model.pth)에서 이어서 학습합니다.")

    n_normal = train_labels.count(0)
    n_anomaly = train_labels.count(1)
    if n_normal > 0 and n_anomaly > 0:
        weight_normal = len(train_labels) / (2.0 * n_normal)
        weight_anomaly = len(train_labels) / (2.0 * n_anomaly)
        class_weights = torch.tensor([weight_normal, weight_anomaly], dtype=torch.float32).to(device)
        print(f"  클래스 가중치: 정상={weight_normal:.2f}, 이상={weight_anomaly:.2f}")
    else:
        class_weights = None

    loss_fn = nn.CrossEntropyLoss(weight=class_weights)
    optimizer = optim.Adam(model.parameters(), lr=args.lr)

    scheduler = optim.lr_scheduler.ReduceLROnPlateau(
        optimizer, mode='max', factor=0.5, patience=10, verbose=True
    )

    best_f1 = -1.0 

    print("\n" + "=" * 55)

    for epoch in range(1, args.epochs + 1):
        print(f"\n📘 에포크 {epoch}/{args.epochs}")
        print("-" * 40)

        train_loss, train_acc = train_one_epoch(
            model, train_loader, optimizer, loss_fn, device
        )

        test_loss, test_acc, test_f1, _, _ = evaluate(
            model, test_loader, loss_fn, device
        )

        print(f"  학습  → 손실: {train_loss:.4f}, 정확도: {train_acc:.2%}")
        print(f"  테스트 → 손실: {test_loss:.4f}, 정확도: {test_acc:.2%}, F1: {test_f1:.4f}")

        scheduler.step(test_f1)

        if test_f1 > best_f1:
            best_f1 = test_f1
            torch.save(model.state_dict(), "best_model.pth")
            print(f"  ✅ 최고 모델 저장! (F1: {best_f1:.4f})")

    print("\n" + "=" * 55)
    print("  최종 평가")
    print("=" * 55)

    model.load_state_dict(torch.load("best_model.pth", weights_only=True))

    _, final_acc, final_f1, preds, targets = evaluate(
        model, test_loader, loss_fn, device
    )

    print(f"\n  정확도: {final_acc:.2%}")
    print(f"  F1:     {final_f1:.4f}")

    cm = confusion_matrix(targets, preds)
    print(f"\n  혼동 행렬:")
    print(f"              예측:정상  예측:이상")
    print(f"  실제:정상     {cm[0][0]:5d}     {cm[0][1]:5d}")
    print(f"  실제:이상     {cm[1][0]:5d}     {cm[1][1]:5d}")

    print(f"\n  분류 리포트:")
    print(classification_report(targets, preds, target_names=["정상", "이상"], zero_division=0))

    print(f"✅ 완료! 최고 F1: {best_f1:.4f}")
    print(f"   모델 저장: best_model.pth")


if __name__ == "__main__":
    main()