# read_inmemory_data 실험 결과

상세 설명은 [BLOG.md](/Users/genius00hwan/laboratory/read_inmemory_data/BLOG.md)에 두고, 이 문서는 실제 실행 조건과 결과만 짧게 남긴다.

## 실험 대상

```sql
SELECT user_id, match_score
FROM user_match
WHERE university_id = 1
  AND gender = 'M'
ORDER BY match_score DESC
LIMIT 20;
```

비교 대상:

- `plain`: `(university_id, gender, match_score DESC)`
- `covering`: `(university_id, gender, match_score DESC, user_id)`
- `redis`: 결과 JSON 캐시

## 데이터셋

- total_rows: `2,000,000`
- matched_rows: `405,919`
- matched_ratio: `20.30%`

실행 스크립트:

- 적재: [seed_user_match.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/seed_user_match.py)
- 단건 벤치: [bench_user_match.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/bench_user_match.py)
- 시나리오 스위트: [run_benchmark_suite.py](/Users/genius00hwan/laboratory/read_inmemory_data/tools/run_benchmark_suite.py)

원본 결과:

- [summary.md](/Users/genius00hwan/laboratory/read_inmemory_data/out/suite_2m/summary.md)
- [summary.json](/Users/genius00hwan/laboratory/read_inmemory_data/out/suite_2m/summary.json)

## 시나리오

| scenario | description | requests | warmup | concurrency |
|---|---|---:|---:|---:|
| interactive_single | 단건 응답 시간 위주 | 3000 | 300 | 1 |
| steady_api | 일반적인 API 핫패스 | 8000 | 500 | 8 |
| burst_hot_key | 같은 조회가 몰리는 버스트 | 16000 | 1000 | 32 |

## 결과

| scenario | case | avg_ms | p95_ms | max_ms | tps |
|---|---|---:|---:|---:|---:|
| interactive_single | plain | 0.828 | 1.546 | 29.800 | 1207.25 |
| interactive_single | covering | 0.888 | 1.536 | 13.499 | 1176.80 |
| interactive_single | redis | 0.401 | 0.650 | 9.462 | 2489.13 |
| steady_api | plain | 2.930 | 6.102 | 29.682 | 2693.88 |
| steady_api | covering | 1.853 | 3.743 | 10.998 | 4280.10 |
| steady_api | redis | 0.774 | 1.307 | 5.193 | 10277.76 |
| burst_hot_key | plain | 13.031 | 26.904 | 93.980 | 2401.61 |
| burst_hot_key | covering | 12.099 | 27.690 | 115.777 | 2618.47 |
| burst_hot_key | redis | 1.977 | 3.940 | 50.603 | 16067.44 |

## 요약 해석

- 저부하 단건 구간에서는 `plain`과 `covering` 차이가 거의 없었다. 반환 행이 20개뿐이라 PK lookup 비용이 작게 끝난다.
- 중간 부하에서는 `covering`이 `plain` 대비 평균 36.8%, p95 38.7% 개선됐다.
- 버스트에서는 `covering`이 평균만 소폭 개선됐고 p95는 사실상 비슷했다. 이 구간에서는 MySQL 엔진 오버헤드 자체가 병목에 가까워졌다.
- Redis는 세 시나리오 모두 가장 빨랐지만, 의미 있는 도입 기준은 퍼센트보다 절대 차이다.
- `interactive_single`에서는 Redis가 더 빨라도 절대 차이는 약 `0.49ms` 수준이다.
- `burst_hot_key`에서는 Redis가 `covering` 대비 평균 `10ms+`, p95 `23ms+` 차이를 내서 도입 명분이 커진다.

## 판단 기준

커버링 인덱스로 충분한 경우:

- 단건 응답 시간이 이미 1~2ms대다
- p95가 서비스 SLO 안에 들어온다
- 동일 조회가 초고빈도 hot key는 아니다
- 최신성이 중요하고 캐시 무효화 복잡도를 늘리고 싶지 않다

Redis 캐시가 적합한 경우:

- 같은 조회가 짧은 시간에 반복된다
- 높은 동시성이나 버스트에서 p95가 급격히 튄다
- DB 부하 여유가 부족하다
- 약간의 캐시 stale 허용과 무효화 설계를 감당할 수 있다
