# Custom Event Queue Design & Tail Latency Exploration (C++20)

고빈도 이벤트 처리 환경을 가정해 여러 큐 설계를 직접 구현하고, **경쟁 구조(concurrency)** 와 **backpressure 정책(block vs drop)** 이 **tail latency(p95/p99)** 에 미치는 영향을 **구현·측정·비교**하는 프로젝트 
**설계 선택이 지연 분포에 어떤 형태로 반영되는지**를 관찰하는 것이 목표입니다.

---

## 궁금한 것들

- 락 기반 큐에서 tail latency(p95/p99)는 왜 급격히 악화되는가?
- 락을 제거하지 않더라도 경쟁 구간을 줄이면 p99가 얼마나 개선되는가?
- lock-free 구조는 어떤 조건에서 가장 큰 이점을 보이는가?
- 과부하 상황에서 backpressure 정책(block vs drop)은 지연과 손실에 어떤 트레이드오프를 만드는가?

---

## Scope

### In
- In-memory 이벤트 큐 직접 구현
- Producer / Consumer 이벤트 파이프라인
- 성능 측정: TPS, avg, p95, p99 latency, drop count
- 동일 조건에서 여러 큐 설계 전략 비교 실험

### Out
- 실제 비즈니스 로직
- 분산 시스템
- 완전한 범용 MPMC 큐(Michael–Scott 계열)
- 장애 복구 / 영속 스토리지

> 본 프로젝트는 실무용 범용 큐 라이브러리를 대체하려는 목적이 아니라, 설계 선택의 영향 관찰을 목적으로 합니다.

---

## High-level Architecture
```
Producer Thread(s)
↓
Event Queue (variant)
↓
Consumer Thread(s)
↓
Latency / Throughput Metrics
```


- Producer는 고정 비율로 이벤트를 생성합니다.
- Consumer는 이벤트를 소비하며 지연을 측정합니다.
- Queue 구현만 교체하여 동일 조건에서 비교합니다.

---

## Queue Variants (Planned)

1. **Single Lock + Condition Variable** (baseline)
2. **Two-Lock Queue (Head/Tail Split)**
3. **Lock-free SPSC Ring Buffer**
4. **MPSC + Drain (Batch Consumer)**

---

## Experiment Axes

- **Concurrency**
  - S1: 1 Producer / 1 Consumer
  - S2: 4 Producers / 1 Consumer
- **Backpressure**
  - Block: 큐가 가득 차면 Producer 대기
  - Drop: 큐가 가득 차면 이벤트 폐기

---

## Metrics

- Throughput (TPS)
- Average latency
- p95 latency
- p99 latency
- Drop count (Drop 정책 사용 시)

Latency는 이벤트 생성 시점과 소비 시점의 차이로 계산합니다.

---

## Hypotheses

- 락 기반 큐는 평균 지연보다 **tail latency(p99)** 에서 더 큰 문제를 드러낸다.
- 경쟁 구간을 분리하면 락을 제거하지 않아도 **p99는 유의미하게 개선**된다.
- lock-free 구조는 **낮은 경합(SPSC)** 환경에서 가장 큰 이점을 보인다.
- backpressure는 성능 최적화가 아니라 **지연 vs 손실의 정책적 선택**이다.

---

## Implementation Principles

- C++20
- RAII 기반 자원 관리
- 단순하고 재현 가능한 구조 우선
- 최적화보다 측정 가능성 우선
- 실험 결과는 반드시 수치로

---

## Status

- [x] Benchmark harness (runner / metrics) - Day1 기본틀
- [ ] Queue variants implementation (4)
- [ ] Experiment runs (S1/S2 × block/drop)
- [ ] Results + interpretation in README

---

## Quickstart (빌드/실행)

### Build
```bash
cmake -S . -B build
cmake --build build -j
```

### Run
```bash
./build/custom_event_queue --duration 10 --warmup 2 --producers 4 --capacity 1024 --rate 50000 --policy block --queue mutex
```

출력 예시(형식):
- `tps`: 측정 구간(duration) 기준 처리량
- `avg_us`, `p95_us`, `p99_us`: latency 마이크로초 단위
- `drop`: drop 정책에서 버려진 이벤트 수
