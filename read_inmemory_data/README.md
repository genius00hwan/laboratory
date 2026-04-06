# read_inmemory_data

고정된 조회 1건에 대해 MySQL 비커버링 인덱스, MySQL 커버링 인덱스, Redis 캐시를 비교하는 최소 실험 환경이다.

## Quickstart

```bash
cd /Users/genius00hwan/laboratory/read_inmemory_data
docker compose up -d
source ./env.sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

테이블 생성:

```bash
mysql_lab < sql/set_user_match.sql
```

데이터 적재:

```bash
python3 tools/seed_user_match.py --rows 2000000 --batch-size 10000 --truncate
```

1차 벤치마크:

```bash
.venv/bin/python tools/run_benchmark_suite.py --repeats 2
```

고정 쿼리:

```sql
SELECT user_id, match_score
FROM user_match
WHERE university_id = 1
  AND gender = 'M'
ORDER BY match_score DESC
LIMIT 20;
```

산출물:

- 단건 벤치: `out/query_cache_bench_smoke.md`
- 시나리오 스위트: `out/suite_2m/summary.md`
