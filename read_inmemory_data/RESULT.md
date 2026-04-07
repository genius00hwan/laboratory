# read_inmemory_data 실험 보고서

이 문서는 [BLOG.md](/Users/genius00hwan/laboratory/read_inmemory_data/BLOG.md)의 서술형 설명과 별도로, 실험 목적, 통제 조건, 측정 결과, 해석, 한계를 보고서 형식으로 정리한 결과 문서다.

## 1. 실험 목적

본 실험의 목적은 고정된 조회 요청 1건에 대해 다음 세 접근 방식을 비교하는 것이다.

- MySQL 비커버링 인덱스 조회
- MySQL 커버링 인덱스 조회
- Redis 결과 캐시 조회

이번 비교에서 가장 중요한 전제는 다음과 같다.

> 둘 다 메모리에서 읽는다면, 페이지 캐시 기반 조회와 결과 캐시 기반 조회는 어떻게 달라지는가?

즉 본 실험은 "Redis는 메모리, MySQL은 디스크"라는 단순 구도로 비교하지 않는다.
MySQL 역시 버퍼 풀에 relevant page working set이 올라온 상태를 만들고, Redis와 동일한 메모리 예산을 부여한 뒤 성능을 비교한다.

## 2. 실험 질문

본 실험은 다음 질문에 답하는 것을 목표로 한다.

1. 동일한 메모리 예산과 warm 상태에서 Redis 결과 캐시는 MySQL보다 여전히 빠른가?
2. 커버링 인덱스는 메모리-resident 조건에서도 plain index보다 항상 유리한가?
3. 저부하 단건, 일반 API 부하, hot key burst 상황에서 각각 어떤 전략이 더 적합한가?

## 3. 대상 조회와 비교군

실험 대상 조회는 다음 쿼리로 고정했다.

```sql
SELECT user_id, match_score
FROM user_match
WHERE university_id = 1
  AND gender = 'M'
ORDER BY match_score DESC
LIMIT 20;
```

선정 이유는 다음과 같다.

- 조건절이 단순하다
- 정렬이 포함된다
- 반환 컬럼 수가 적다
- 상위 N개 조회 형태로 hot key가 되기 쉽다
- Redis 결과 캐시 후보로 현실성이 있다

비교군은 아래 세 가지다.

### 3.1 `plain`

비커버링 인덱스:

```sql
(university_id, gender, match_score DESC)
```

이 인덱스는 조건절과 정렬을 처리할 수 있지만, `user_id`가 인덱스에 없으므로 결과 조립을 위해 추가 row lookup이 필요할 수 있다.

### 3.2 `covering`

커버링 인덱스:

```sql
(university_id, gender, match_score DESC, user_id)
```

조회에 필요한 컬럼이 모두 인덱스 leaf에 포함되므로, 실행 계획상 `Using index`가 가능하다.

### 3.3 `redis`

결과 캐시:

- key: `user_match:u=1:g=M:limit=20`
- value: 조회 결과 20건 전체를 담은 JSON 문자열

즉 Redis는 질의를 다시 수행하지 않고, 계산된 최종 결과를 키 단위로 재사용한다.

## 4. 실험 환경

- OS/실행 방식: 로컬 Docker Compose
- MySQL: `8.0.36`
- Redis: `7.2`
- 적재/벤치: Python 스크립트
- WAS: 사용하지 않음
- 목적: API 계층 전체가 아니라 조회 계층만 분리 비교

실험에 사용한 주요 파일은 다음과 같다.

- 환경: [docker-compose.yml](/Users/genius00hwan/laboratory/read_inmemory_data/docker-compose.yml)
- 적재 스크립트: [seed_user_match.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/seed_user_match.py)
- 단건 벤치: [bench_user_match.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/bench_user_match.py)
- 스위트 러너: [run_buffer_pool_suite.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/run_buffer_pool_suite.py)
- 원본 결과: [summary.md](/Users/genius00hwan/laboratory/read_inmemory_data/out/suite_2m_buffer_pool/summary.md)

## 5. 데이터셋

실험 데이터셋은 `user_match` 테이블 2,000,000건이다.

- total_rows: `2,000,000`
- matched_rows: `405,919`
- matched_ratio: `20.30%`
- table total size: 약 `182.31MB`
- data size: 약 `112.66MB`
- index size: 약 `69.66MB`

이 수치는 중요한 의미를 가진다.

- MySQL `innodb_buffer_pool_size`는 `256MB`
- `user_match` 전체 크기는 약 `182MB`

즉 이번 MySQL 실험은 디스크 병목을 보려는 실험이 아니라, 거의 메모리-resident 상태에서의 처리 경로 차이를 보는 실험이라고 해석하는 편이 맞다.

## 6. 메모리 예산 및 통제 조건

이번 실험의 핵심은 `"둘 다 메모리에서 읽는다면"`이라는 전제를 흔들지 않는 것이다. 이를 위해 다음 통제 조건을 적용했다.

### 6.1 동일한 메모리 예산

- MySQL `innodb_buffer_pool_size = 256MB`
- Redis `maxmemory = 256MB`

즉 Redis만 과도하게 큰 메모리를 사용하도록 두지 않았고, MySQL도 작은 버퍼 풀로 불리하게 두지 않았다.

### 6.2 버퍼 풀 재시작 정책

- `innodb_buffer_pool_dump_at_shutdown=OFF`
- `innodb_buffer_pool_load_at_startup=OFF`

즉 MySQL 재시작 시 이전 버퍼 풀 상태를 자동 복원하지 않도록 했다.

### 6.3 cold / warm 분리

- `cold`: 인덱스 준비 후 MySQL 재시작, warmup 없이 측정
- `warm`: 인덱스 준비 후 MySQL 재시작, warmup 후 측정

### 6.4 warm 상태 검증

warm 결과는 단순히 "몇 번 실행했으니 아마 메모리에 올라왔을 것"이라고 가정하지 않았다.
측정 구간에서 아래 조건을 만족한 run만 채택했다.

- `benchmark_buffer_pool_reads_delta = 0`

이는 측정 구간 동안 InnoDB가 디스크에서 추가 페이지를 읽지 않았다는 뜻이다.
즉 최종 warm 비교는 적어도 측정 구간 기준으로는 버퍼 풀 hit만으로 처리된 run이다.

### 6.5 Redis 메모리 사용 해석 시 주의점

이번 실험에서 동일하게 맞춘 것은 메모리 ceiling이다.
실제 사용량은 다르다.

- MySQL은 테이블/인덱스 working set을 버퍼 풀에 유지한다
- Redis는 hot query 결과 1개만 저장한다

실측 기준 Redis 사용 메모리는 약 `1MB` 수준이었다. 따라서 본 실험은 "대규모 캐시 공간 전체"를 비교한 것이 아니라, **고정된 hot query 하나를 결과 캐시로 분리했을 때의 구조적 차이**를 본 실험이다.

## 7. 실행 계획

실행 계획은 다음과 같이 확인됐다.

### 7.1 `plain`

- Extra: `Using index condition`
- 의미: 인덱스를 사용하지만, 결과를 인덱스만으로 완결하지 못한다

### 7.2 `covering`

- Extra: `Using where; Using index`
- 의미: 조건을 만족하는 결과를 인덱스만으로 조립할 수 있다

즉 `plain`과 `covering`의 차이는 단순히 "인덱스를 타느냐"가 아니라, **결과 조립을 secondary index leaf만으로 끝낼 수 있느냐**의 차이다.

## 8. 시나리오 정의

실험은 세 가지 시나리오로 나누어 수행했다.

| scenario | description | requests | warmup | concurrency |
|---|---|---:|---:|---:|
| interactive_single | 단건 응답 시간 위주. 사용자 한 명이 반복 조회 | 3000 | 300 | 1 |
| steady_api | 일반적인 API 핫패스 | 8000 | 500 | 8 |
| burst_hot_key | 같은 조회가 짧은 시간에 몰리는 버스트 | 16000 | 1000 | 32 |

지표는 아래 네 가지를 사용했다.

- 평균 응답 시간 `avg_ms`
- p95 응답 시간 `p95_ms`
- 최대 응답 시간 `max_ms`
- 처리량 `tps`

## 9. 측정 결과

### 9.1 warm verified 결과

아래 표는 `benchmark_buffer_pool_reads_delta=0`을 만족한 warm MySQL과 Redis 결과만 따로 정리한 것이다.

| scenario | case | avg_ms | p95_ms | max_ms | tps |
|---|---|---:|---:|---:|---:|
| interactive_single | plain_warm | 0.713 | 1.261 | 16.076 | 1399.53 |
| interactive_single | covering_warm | 0.685 | 1.191 | 8.661 | 1455.71 |
| interactive_single | redis | 0.395 | 0.741 | 13.700 | 2530.21 |
| steady_api | plain_warm | 3.093 | 6.302 | 19.282 | 2566.21 |
| steady_api | covering_warm | 5.423 | 11.958 | 103.447 | 1468.71 |
| steady_api | redis | 2.409 | 5.638 | 261.028 | 3306.56 |
| burst_hot_key | plain_warm | 12.483 | 21.519 | 59.326 | 2518.03 |
| burst_hot_key | covering_warm | 11.325 | 22.966 | 75.720 | 2775.43 |
| burst_hot_key | redis | 3.992 | 8.768 | 144.396 | 7902.94 |

### 9.2 cold / warm 비교 참고

원본 결과 기준 cold/warm 비교는 다음과 같다.

| scenario | cache_state | case | avg_ms | p95_ms | tps |
|---|---|---|---:|---:|---:|
| interactive_single | cold | plain | 1.661 | 3.474 | 600.44 |
| interactive_single | warm | plain | 0.713 | 1.261 | 1399.53 |
| interactive_single | cold | covering | 0.686 | 1.146 | 1453.84 |
| interactive_single | warm | covering | 0.685 | 1.191 | 1455.71 |
| steady_api | cold | plain | 2.887 | 5.464 | 2749.53 |
| steady_api | warm | plain | 3.093 | 6.302 | 2566.21 |
| steady_api | cold | covering | 4.286 | 8.689 | 1847.51 |
| steady_api | warm | covering | 5.423 | 11.958 | 1468.71 |
| burst_hot_key | cold | plain | 17.612 | 35.929 | 1786.50 |
| burst_hot_key | warm | plain | 12.483 | 21.519 | 2518.03 |
| burst_hot_key | cold | covering | 11.125 | 21.812 | 2825.02 |
| burst_hot_key | warm | covering | 11.325 | 22.966 | 2775.43 |

이 표에서 일부 구간은 cold와 warm 차이가 작거나 warm이 오히려 느리게 보인다. 이는 이번 데이터셋이 메모리 예산 안에 상당 부분 수용되고, OS cache 및 실행 노이즈 영향도 존재하기 때문이다. 따라서 본 보고서의 핵심 해석은 cold 수치보다 **warm verified 결과**를 중심으로 한다.

## 10. 결과 분석

### 10.1 전체 관찰

전체 결과를 먼저 요약하면 다음과 같다.

- 동일한 메모리 예산에서도 Redis는 세 시나리오 모두 가장 빠른 결과를 보였다
- 그러나 저부하 단건에서는 MySQL 자체가 이미 매우 빨라, Redis 도입의 절대 이득은 작았다
- 커버링 인덱스는 항상 plain index보다 빠르지 않았다
- burst 상황에서는 Redis가 avg뿐 아니라 p95에서도 구조적으로 우위였다

즉 본 실험은 "Redis가 항상 절대적으로 우월하다"는 결론보다, **어떤 비용을 줄이느냐에 따라 최적 전략이 달라진다**는 점을 보여준다.

### 10.2 `interactive_single` 분석

`interactive_single`은 단건 요청 위주 시나리오다.

- plain_warm avg: `0.713ms`
- covering_warm avg: `0.685ms`
- redis avg: `0.395ms`

이 구간에서 `plain`과 `covering` 차이는 거의 없다. Redis가 가장 빠르지만, `covering -> redis` 절대 차이는 약 `0.29ms`에 불과하다.

이 결과는 쿼리 구조를 보면 자연스럽다.

- 정렬 조건이 인덱스 순서와 맞는다
- `LIMIT 20`이라 상위 20건만 찾으면 된다
- warm 상태에서는 row lookup도 버퍼 풀 hit일 가능성이 높다

즉 `plain`이 추가로 부담하는 비용은 "상위 20건 정도에 대한 row lookup" 수준으로 축소된다. 디스크 miss가 없는 상태에서는 그 비용이 매우 작다.

따라서 이 구간의 해석은 다음과 같다.

- MySQL은 이미 충분히 빠르다
- Redis가 더 빠르긴 하지만, 운영 복잡도를 추가할 만큼의 절대 차이인지는 별도 판단이 필요하다
- low concurrency, small result set, hot key burst 없음이라는 조건에서는 DB 최적화만으로 충분할 수 있다

### 10.3 `steady_api` 분석

`steady_api`는 일반적인 API 핫패스를 가정한 시나리오다.

- plain_warm avg: `3.093ms`
- covering_warm avg: `5.423ms`
- redis avg: `2.409ms`
- plain_warm p95: `6.302ms`
- covering_warm p95: `11.958ms`
- redis p95: `5.638ms`

가장 주목할 결과는 `covering`이 `plain`보다 느렸다는 점이다.

이 결과는 커버링 인덱스가 잘못된 전략이라는 뜻이 아니다. 이번 조건에서 **row lookup 제거 이득보다 인덱스 폭 증가 비용이 더 크게 보였을 가능성**을 의미한다.

#### B+Tree 관점 해석

비커버링 인덱스의 leaf에는 대략 아래 정보가 저장된다.

- `university_id`
- `gender`
- `match_score`
- PK

반면 커버링 인덱스는 여기에 `user_id`가 추가된다.
즉 커버링 인덱스는 lookup을 줄이는 대신, leaf entry를 더 넓게 만든다.

그 결과 다음 현상이 생길 수 있다.

- 같은 `16KB` page에 들어가는 entry 수 감소
- leaf page 밀도 하락
- 더 많은 page 접근 가능성 증가
- CPU cache locality 저하
- 메모리 밀도 저하

원래 커버링 인덱스의 장점은 명확하다.

- PK 기반 row lookup 제거
- clustered index 재조회 제거
- 랜덤 접근 감소

그러나 이번 쿼리는 `LIMIT 20`이므로, `plain`이 추가로 치르는 row lookup 수 자체가 작다. 그리고 그 lookup도 메모리 hit라면 penalty가 더 줄어든다.

결국 이번 구간에서는

- 커버링이 줄여주는 lookup 비용

보다

- 커버링이 늘린 인덱스 폭 비용

이 더 크게 나타났다고 해석할 수 있다.

즉 본 실험은 `covering = always fastest`가 아니라, **row lookup이 충분히 비쌀 때 강한 전략**이라는 점을 보여준다.

### 10.4 `burst_hot_key` 분석

`burst_hot_key`는 동일 조회가 짧은 시간에 몰리는 시나리오다.

- plain_warm avg: `12.483ms`
- covering_warm avg: `11.325ms`
- redis avg: `3.992ms`
- plain_warm p95: `21.519ms`
- covering_warm p95: `22.966ms`
- redis p95: `8.768ms`

이 구간에서는 `plain`과 `covering`의 차이보다, MySQL과 Redis의 처리 구조 차이가 훨씬 더 중요하다.

MySQL은 warm 상태에서도 요청마다 아래 과정을 반복한다.

1. SQL 요청 수신
2. 실행기 진입
3. 인덱스 range 탐색
4. leaf scan
5. 결과 조립
6. protocol row 직렬화
7. 클라이언트 전송

반면 Redis는 다음과 같다.

1. key lookup
2. value fetch
3. 이미 계산된 JSON 반환

즉 둘 다 메모리에서 읽더라도, MySQL은 매 요청마다 질의를 다시 수행하고 Redis는 결과를 재사용한다.

#### p95가 크게 벌어진 이유

동시성 `32` 구간에서는 tail latency가 단순 계산 시간만으로 결정되지 않는다.

- 실제 처리 시간
- 앞선 요청을 기다린 시간

이 누적되면서 p95가 커진다.

Redis는 요청당 서비스 시간이 짧아서 대기열이 덜 쌓인다.
따라서 avg 차이뿐 아니라 p95 차이가 더 크게 나타난다.

이번 결과에서 핵심은 다음이다.

- MySQL 두 전략은 모두 `10ms`대 avg, `20ms`대 p95
- Redis는 `3ms`대 avg, `8ms`대 p95

즉 burst 상황에서는 "어떤 인덱스를 쓰느냐"보다, **질의를 계속 수행하느냐 vs 결과를 재사용하느냐**가 더 큰 축이 된다.

## 11. 실무 판단 기준

### 11.1 커버링 인덱스로 충분한 경우

다음 조건이면 우선 MySQL 최적화만으로 끝내는 편이 합리적이다.

- 조회 패턴이 단순하다
- 반환 행 수가 작다
- `LIMIT`이 작아 row lookup 비용이 작다
- warm 기준 avg/p95가 서비스 요구사항 내에 있다
- 최신성이 중요하다
- 캐시 무효화 복잡도를 피하고 싶다
- hot key burst가 크지 않다

### 11.2 Redis 결과 캐시가 적합한 경우

다음 조건이면 Redis 도입 명분이 커진다.

- 동일 조회가 매우 자주 반복된다
- hot key가 명확하다
- burst 상황에서 p95가 급격히 상승한다
- DB 최적화 후에도 처리량 여유가 부족하다
- stale 허용 범위와 무효화 전략을 운영할 수 있다

### 11.3 본 실험에 대한 적용

본 실험 결과에 한정하면 다음과 같이 정리할 수 있다.

- `interactive_single`: MySQL만으로도 충분히 실용적이다
- `steady_api`: 커버링 인덱스가 자동으로 정답이 아니며, 실제 측정이 필요하다
- `burst_hot_key`: Redis 결과 캐시의 구조적 이점이 분명하다

## 12. 한계와 주의사항

본 실험에는 다음 한계가 있다.

### 12.1 조회 패턴이 하나뿐이다

이번 결과는 특정 상위 N개 조회 1건에 대한 결과다.
다른 조건절, 더 큰 결과 집합, 다른 정렬 패턴에서는 결과가 달라질 수 있다.

### 12.2 Redis는 고정 조회 결과 1개만 저장했다

즉 대규모 캐시 키 공간 운영, eviction, 캐시 오염, 키 cardinality 문제는 포함하지 않았다.

### 12.3 로컬 단일 머신 실험이다

네트워크 홉, 애플리케이션 직렬화 비용, 멀티 인스턴스 경쟁, 실제 운영 트래픽 패턴은 반영하지 않았다.

### 12.4 데이터셋이 메모리 예산 안에 상당 부분 들어간다

따라서 이번 실험은 디스크 병목보다 메모리-resident 상태의 구조 차이를 강조하는 실험이다. 더 큰 데이터셋이나 더 작은 버퍼 풀에서는 다른 양상이 나타날 수 있다.

## 13. 결론

본 실험을 통해 확인한 결론은 다음과 같다.

1. 동일한 메모리 예산과 warm 상태에서도 Redis 결과 캐시는 MySQL보다 빠를 수 있다.
2. 그 이유는 단순히 "Redis가 메모리라서"가 아니라, 질의를 다시 수행하지 않고 완성된 결과를 재사용하기 때문이다.
3. 커버링 인덱스는 강력한 최적화지만, 메모리 hit 위주의 작은 `LIMIT` 조회에서는 항상 비커버링 인덱스보다 빠르지 않다.
4. 저부하 단건에서는 MySQL만으로도 충분히 실용적일 수 있다.
5. 반면 hot key burst에서는 Redis가 avg뿐 아니라 p95에서도 분명한 우위를 보였다.

따라서 실무에서는 다음 순서가 합리적이다.

1. 먼저 쿼리와 인덱스 구조를 정리한다
2. 커버링 인덱스가 실제로 이득인지 측정한다
3. 그래도 hot key 반복과 burst에서 tail latency가 무너지면 Redis 결과 캐시를 도입한다

즉 이번 실험의 최종 결론은 다음 한 문장으로 요약할 수 있다.

> 메모리 위의 MySQL과 Redis를 비교해도 차이는 남는다. 다만 그 차이를 만드는 핵심은 "메모리 여부"보다 "질의를 다시 하느냐, 결과를 재사용하느냐"에 있다.
