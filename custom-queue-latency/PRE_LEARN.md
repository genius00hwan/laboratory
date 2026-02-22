# 실험 전에 갖춰야 할 사전지식


## 1) Latency 분포와 퍼센타일 감각

- **avg(평균)**: 대부분의 정상 구간을 반영하지만, “가끔 터지는 큰 지연”을 잘 숨긴다.
- **p95/p99**: 상위 5%/1%의 지연을 보여준다. 락 경합/스케줄링/캐시/오버로드가 주로 tail에 드러난다.
- **p99는 흔들린다**
  - 샘플 수가 적으면 p99가 통계적으로 불안정해진다.
  - 충분한 이벤트 수(수십만~수백만) + 반복 실행이 필요하다.

---

## 2) 오버로드(과부하)와 큐잉(Queueing) 기본

- 생산률 x > 소비률 y 이면 큐는 언젠가 반드시 포화되고 **대기(block) 또는 드롭(drop)** 이 발생한다.
- x가 y보다 약간 낮아도(사용률이 1에 가까우면) **tail latency가 급격히 악화**될 수 있다.
- 실험에서 중요한 포인트
  - “언제 p99가 폭발하는가(=임계점)”
  - “설계가 임계점을 얼마나 이동시키는가”

---

## 3) 락 기반 동기화가 tail을 망치는 원인

- **경합(Contention)**: 많은 스레드가 같은 락을 잡으려 함
- **OS 스케줄러 개입**: 경쟁이 심하면 블로킹/웨이크업 비용이 커짐
- **컨텍스트 스위치**: runnable <-> blocked 전환이 tail에 큰 꼬리를 만든다
- **Convoy(줄서기) 효과**: 느린 스레드/타이밍 문제로 뒤가 연쇄적으로 밀린다
- **Thundering herd**: 다수 스레드가 동시에 깨고 재경쟁하며 tail이 악화된다(특히 notify_all)

---

## 4) condition_variable 올바른 사용 패턴

- `wait(lock, predicate)` 형태의 predicate 기반 대기가 기본(스퓨리어스 웨이크업 대비).
- `notify_one` vs `notify_all`은 tail에 영향을 크게 줄 수 있다.
- block 정책 구현에서 CV 사용 방식이 결과를 지배할 수 있으므로 패턴을 정확하게 가져가야 함.

---

## 5) Bounded Buffer에서 Backpressure 정책의 의미

- **Block**
  - 장점: 손실 없음
  - 단점: 오버로드 시 대기 누적 → 지연 폭발(p99 악화)
- **Drop**
  - 장점: 지연을 억제 가능
  - 단점: 이벤트 손실 발생(품질 저하)

> 결론: backpressure는 지연과 손실사이의 트레이드오프에 따라 정의하자.
> 실험 결과는 반드시 `drop count`와 함께 해석하자.

---

## 6) CPU 캐시 / 캐시라인 / False Sharing

- 캐시라인(보통 64B) 단위로 공유/무효화가 발생한다.
- 서로 다른 스레드가 같은 캐시라인의 다른 변수를 갱신하면 **false sharing**으로 성능이 무너질 수 있다.
- 특히 lock-free ring buffer에서
  - `head`와 `tail`을 **cache line 분리(alignas(64))** 하지 않으면 tail이 쉽게 튄다.

---

## 7) C++ Atomic과 메모리 오더 (Acquire/Release)

SPSC ring buffer 같은 lock-free 구조의 핵심:

- producer: 데이터 쓰기 → `tail.store(..., release)`
- consumer: `tail.load(acquire)` → 데이터 읽기

이 규칙이 깨지면
- consumer가 최신 데이터를 “쓴 것처럼 보이지만 실제로는 덜 쓴 상태”를 보게 되는 식의 오류가 발생 가능하다.

---

## 8) Lock-free의 전제와 한계

- SPSC는 lock-free가 가장 깔끔하게 먹히는 영역(단일 생산자/단일 소비자).
- MPSC/MPMC로 갈수록
  - CAS 경합, ABA, 메모리 회수(reclamation) 등 복잡도가 급증한다.
- 본 프로젝트는 범용 MPMC를 목표로 하지 않으므로,
  - “왜 SPSC에서는 크게 이기는데 경쟁이 늘면 이점이 줄어드는지” 정도의 감각이면 충분하다.

---

## 9) 배치(drain) 처리의 장단점

- 장점: 고정 비용(락/원자 연산/캐시미스)을 N개에 분산(amortize) → 평균/때로는 tail 개선
- 단점: 배치 주기/크기가 커지면 “대기 시간이 tail로 전이”될 수 있음
- 따라서 drain 전략은 새로운 튜닝 축(배치 크기/빈도)을 만든다.

---

## 10) 벤치마크 신뢰도를 좌우하는 기본기

- **Warmup / Measure 분리** (예: warmup 2s + measure 8s)
- **steady_clock 사용** (벽시계/시스템 시간 변화 영향 배제)
- **Rate limiter 설계 주의**
  - 너무 잦은 `sleep`은 지연 측정에 잡음
  - 과한 busy-wait는 CPU 점유로 다른 스레드에 영향을 줌
- 가능하면
  - 스레드 핀ning(코어 고정)
  - CPU governor(성능 모드)
  - 외부 노이즈 최소화(백그라운드 작업)

---

## 11) 공정 비교를 위한 “고정해야 하는 것” 체크리스트

큐만 바꾸고 아래는 고정해야 비교가 의미 있다.

- capacity
- producer/consumer 수
- event size(구조체 크기)
- consumer work(처리 비용)
- backpressure 정책(block/drop)
- latency 정의(시작 시점/종료 시점)

---