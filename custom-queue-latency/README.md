# custom-queue-latency

Phase 4 기준으로 정리한 C++ queue benchmark 프로젝트입니다.

이 저장소의 핵심은 예전 benchmark를 많이 남겨두는 것이 아니라, 해석 가능한 비교만 남기는 것입니다.

Phase 4의 코어 질문은 세 가지뿐입니다.

1. shared queue를 유지해야 한다면 `split_lock`와 `mpmc_ring` 중 무엇이 더 설득력 있는가
2. local SPSC topology를 허용한다면 `dispatch_local_spsc`와 `direct_local_spsc` 중 무엇이 더 낫는가
3. 최종적으로 shared winner와 local winner를 붙이면 어떤 전략이 더 나은가

## Phase 4 Interpretation Rules

- `GlobalLockQueue`는 historical baseline일 뿐이며 core matrix에서 제외한다
- `SpscRingQueue`를 shared multithreaded queue primitive처럼 비교하지 않는다
- `spsc` 결과는 항상 topology 이름과 함께 읽는다
  - `dispatch_local_spsc`
  - `direct_local_spsc`
- shared family 비교와 local family 비교를 먼저 끝낸 뒤에만 strategy 비교를 읽는다
- direct local SPSC는 현재 `ingress <= workers`의 고정 affinity 모델이다
  - full route matrix / high fan-in direct route는 다음 slice의 TODO다

## Active Layout

```text
src/
  queues.*            shared queue primitives + SPSC ring + stats
  pipeline.*          Phase 4 topology benchmark core
  main.cpp            primitive queue CLI
  pipeline_main.cpp   active Phase 4 pipeline CLI
  harness.*           primitive queue harness

tools/
  run_phase4_matrix.py

tests/
  test_queue_strategies.cpp
  test_pipeline.cpp
  test_scenario.cpp
```

## Phase 4 Architecture

### A. Shared Queue Family

비교 대상:

- `shared_split_lock`
- `shared_mpmc_ring`

의미:

- 같은 shared queue pipeline 위치에서 shared primitive만 비교한다
- 여기서 얻는 결론은 shared family 내부 winner뿐이다

### B. Local Queue Family

비교 대상:

- `dispatch_local_spsc`
- `direct_local_spsc`

의미:

- 둘 다 worker-local SPSC를 사용하지만 topology가 다르다
- 차이는 `dispatcher hop`의 존재 여부다

### C. Strategy Comparison

비교 대상:

- shared family winner
- local family winner

의미:

- family-level 비교를 끝낸 뒤 최종 전략만 붙인다
- family 내부 loser를 final matrix에 계속 남겨서 noise를 늘리지 않는다

## Reduced Benchmark Matrix

Phase 4 기본 실행 세트는 아래 네 가지 비교만 남긴다.

| track | case | variants | purpose |
| --- | --- | --- | --- |
| `shared` | `block_near_sat` | `shared_split_lock`, `shared_mpmc_ring` | shared queue의 기본 block tail 비교 |
| `shared` | `overload_drop` | `shared_split_lock`, `shared_mpmc_ring` | shared queue의 overload/drop 비교 |
| `local` | `block_near_sat` | `dispatch_local_spsc`, `direct_local_spsc` | dispatcher hop의 block tail 영향 비교 |
| `local` | `overload_drop` | `dispatch_local_spsc`, `direct_local_spsc` | local topology의 overload/drop 비교 |

Strategy track은 finalist 둘만 비교한다.

| track | case | variants | purpose |
| --- | --- | --- | --- |
| `strategy` | `block_near_sat` | `shared finalist`, `local finalist` | 기본 steady-state 최종 비교 |
| `strategy` | `overload_drop` | `shared finalist`, `local finalist` | overload 시 최종 전략 비교 |

왜 이 정도만 남기는가:

- shared primitive 질문은 shared family 두 개면 충분하다
- local topology 질문은 local family 두 개면 충분하다
- winner vs winner는 finalist 두 개면 충분하다
- 더 많은 조합은 해석력보다 noise를 늘릴 가능성이 크다

## New Config Model

Phase 4 runner는 primitive 중심이 아니라 family 중심이다.

핵심 필드:

- `track`: `shared`, `local`, `strategy`
- `case`: `block_near_sat`, `overload_drop`
- `variant`: Phase 4의 네 가지 이름 중 하나
- `topology`: `shared`, `dispatch_local_spsc`, `direct_local_spsc`
- `shared_queue`: `split_lock` 또는 `mpmc_ring`
- `dispatch_queue`: 현재 local topology의 shared ingress queue 종류
- `policy`: `block` 또는 `drop`
- `wait_strategy`: 현재는 `default`를 코어 경로로 유지
- `ingress_threads`, `worker_threads`
- `ingress_queue_capacity`, `worker_queue_capacity`
- `service_ns`, `jitter_ns`

중요:

- `queue=spsc` 같은 naked primitive case는 Phase 4 core runner에서 사용하지 않는다
- strategy track은 `--shared-finalist`, `--local-finalist`로 finalist를 명시한다

## Build

```bash
cmake -S . -B build-local
cmake --build build-local -j
ctest --test-dir build-local --output-on-failure
```

## Run

### 1. Shared Family

```bash
python3 tools/run_phase4_matrix.py --track shared
```

### 2. Local Family

```bash
python3 tools/run_phase4_matrix.py --track local
```

### 3. Final Strategy Comparison

기본 finalist는 아래처럼 둔다.

- shared finalist: `split_lock`
- local finalist: `direct_local_spsc`

```bash
python3 tools/run_phase4_matrix.py --track strategy
```

winner를 바꿔서 다시 비교하려면:

```bash
python3 tools/run_phase4_matrix.py --track strategy \
  --shared-finalist mpmc_ring \
  --local-finalist dispatch_local_spsc
```

### 4. Smoke Run

```bash
python3 tools/run_phase4_matrix.py --track all --smoke
```

기본 출력:

- `out/phase4/<timestamp>/raw_results.csv`
- `out/phase4/<timestamp>/summary.md`
- `out/phase4/<timestamp>/manifest.json`

## Required Metrics

Phase 4 코어 해석에 필요한 메트릭만 유지한다.

- throughput: `tps_completed`
- latency: `avg_us`, `p95_us`, `p99_us`
- completion / drop: `generated`, `accepted`, `completed`, `dropped`
- drop location: `dropped_ingress`, `dropped_dispatch`
- queue pressure:
  - `ingress_full_hits`, `ingress_empty_hits`, `ingress_max_observed_depth`
  - `worker_full_hits`, `worker_empty_hits`, `worker_max_observed_depth`
- wait activity:
  - `ingress_spin_count`, `ingress_yield_count`, `ingress_park_count`
  - `worker_spin_count`, `worker_yield_count`, `worker_park_count`
- worker balance:
  - `worker_completed_min`
  - `worker_completed_max`
  - `worker_imbalance_pct`

## Code Refactor Plan

이미 반영된 것:

- `QueueKind::MpmcRing` 추가
- `PipelineTopology`를 `SharedQueue`, `DispatchLocalSpsc`, `DirectLocalSpsc`로 정리
- `custom_event_pipeline` CLI를 Phase 4 topology 이름 기준으로 갱신
- Phase 4와 무관한 과거 문서/러너 제거

다음으로 남은 것:

1. `direct_local_spsc`의 full route matrix 확장
2. topology별 wait strategy 분리
3. skew / high fan-in direct route 실험 지원
4. family winner를 자동 선택하는 post-processing 정리

## Step-by-Step Implementation Order

1. shared family와 local family를 강제하는 topology / queue model 정리
2. `MPMCRingQueue` 추가
3. `direct_local_spsc` 추가
4. 과거 phase 문서와 runner 제거
5. Phase 4 runner를 새 메인 경로로 추가
6. README를 Phase 4 기준으로 교체
7. high fan-in direct route / skew / topology-specific wait를 다음 slice로 넘김
