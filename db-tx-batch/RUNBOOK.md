# db-tx-batch Runbook (MySQL) — 핵심 실험 스크립트 & 실행 가이드

**핵심 실험을 바로 실행**할 수 있게 커맨드/스크립트를 모아둔 실행용 문서.

> 안전장치: 아래 러너들은 기본적으로 `DROP`/`TRUNCATE orders`를 하지 않습니다.  
> 단, 일부 실험(집계 range)은 **실제 `orders.amount`를 UPDATE** 하므로 범위/속도를 조절해서 돌리세요.

## 카테고리별 문서 정리

스크립트는 다음 디렉토리로 분류되어 있다.

- 공통 준비: `experiments/00_setup/`
- 큐 클레임(good vs bad): `experiments/10_queue_claim/`
- 집계/스냅샷: `experiments/20_agg_snapshot/`
- 락벤치(performance_schema): `experiments/30_lockbench/`
- gap/next-key 벤치: `experiments/40_gaplock/`
- chunk mixed snapshot: `experiments/50_chunk_demo/`
- undo/purge(History list length): `experiments/60_undo_purge/`

## 가설 A/B/C/D 기준 실행 순서

- **가설 A**: `bash tools/run_agg_range_rc_rr_nodrop.sh 1 100000` → `bash tools/run_orders_range_sweep.sh "..."`
- **가설 B**: `bash tools/run_gaplock_bench_nodrop.sh ...` → `bash tools/run_undo_history_len_bench.sh ...`
- **가설 C**: `bash tools/run_isolation_lockbench_nodrop.sh` → sweep에서 `SERIALIZABLE`만 반복
- **가설 D**: `experiments/10_queue_claim/*` 수동 재현 → `bash tools/run_queue_claim_bench_nodrop.sh ...`

## 0) 공통 준비

```bash
docker compose up -d
source ./env.sh
```

### 0-1) 성능 지표(performance_schema) 권한 (1회)

```bash
mysql_root_lab < experiments/30_lockbench/grant_perf_schema.sql
```

### 0-2) 현재 DB 세팅 캡처 (기록용)

```bash
mysql_lab < experiments/00_setup/capture_mysql_settings.sql
```

### 0-3) 대용량(수천만~수억) 시드 준비

```bash
mysql_lab < tools/bootstrap_sequences.sql
```

용량 확인:

```bash
mysql_lab < tools/table_stats.sql
```

## 1) “락 대기/데드락” 숫자 뽑기 (RC/RR/SERIALIZABLE)

**목적**: 격리수준별로 `lock wait / deadlock / timeout`이 숫자로 어떻게 달라지는지 보기.

실행:

```bash
bash tools/run_isolation_lockbench_nodrop.sh
```

무엇을 해석하나:

- `lockwait_waited_ms`: row lock을 기다린 시간(ms)
- `deadlocks_delta`, `lock_wait_timeouts_delta`: performance_schema 누적 카운터의 전/후 diff

## 2) 집계 배치 RC/RR 차이(“같은 tx에서 두 번 읽었는데 SUM이 달라짐”) 재현

**목적**: RC의 non-repeatable read 성격을 집계 배치 시나리오로 재현하고, RR/Serializable에서 스냅샷이 얼마나 안정적인지 보기.

실행(범위 작게부터 추천):

```bash
bash tools/run_agg_range_rc_rr_nodrop.sh 1 100000
```

SERIALIZABLE만 따로:

```bash
bash tools/run_agg_range_rc_rr_nodrop.sh 1 50000000 "SERIALIZABLE"
```

주의:

- 이 실험은 해당 범위 `orders.amount`를 실제로 `+1` 업데이트합니다.
- 범위가 커질수록 OLTP UPDATE가 오래 걸리고(또는 1205/1213) undo 부담이 커집니다.

## 3) (대용량 의미 강화) 범위 크기 스윕: wall time / timeout / waited_ms 표 뽑기

**목적**: 범위 크기(100K→1M→10M→50M…)가 커질수록
“정합성(배치 스냅샷) vs 운영비용(OLTP 지연/타임아웃)”이 어떻게 커지는지 **표**로 보기.

실행:

```bash
bash tools/run_orders_range_sweep.sh "100000,1000000" 1 "READ COMMITTED,REPEATABLE READ"
bash tools/run_orders_range_sweep.sh "10000000,50000000" 1 "READ COMMITTED,REPEATABLE READ,SERIALIZABLE"
```

출력에서 보는 것:

- `batch_sum_diff`: 배치 tx 안에서 2번 읽은 SUM 차이 (RC에서 커지기 쉬움)
- `oltp_waited_ms`: OLTP UPDATE 트랜잭션의 전체 소요(ms) (실행+대기 포함)
- `oltp_status`: `OK` 또는 `1205`(lock wait timeout), `1213`(deadlock)

## 4) (가설 B) RR/SERIALIZABLE에서 gap/next-key로 범위 경합이 커지는지

**목적**: “범위 락이 진짜 INSERT를 막는지”를 숫자로 확인.

실행:

```bash
bash tools/run_gaplock_bench_nodrop.sh 100 200 101 5
```

해석:

- RC에서 `inserter_waited_ms`가 0에 가깝고
- RR/SERIALIZABLE에서 `~hold_seconds` 근처면 “줄 서는 시간”이 커졌다고 해석

## 5) (가설 D) 큐 클레임 패턴: good vs bad 정량 비교

**목적**: 격리수준보다 “클레임 패턴”이 중복 시도/처리량에 더 큰 영향을 주는지 확인.

실행(권장: seed_jobs 고정해서 비교):

```bash
bash tools/run_queue_claim_bench_nodrop.sh good 8 20 0.05 "READ COMMITTED" 50000
bash tools/run_queue_claim_bench_nodrop.sh bad  8 20 0.05 "READ COMMITTED" 50000
```

해석:

- `duplicate_errors (1062)`: “중복 처리 시도”의 정량 지표
- `DONE`, `done_per_sec`: 처리량/효율
- SERIALIZABLE에서 `bad` 패턴은 1062가 줄어도 데드락/지연으로 “다른 비용”이 튈 수 있음

## 6) (설계 이슈) chunk commit이 mixed snapshot을 만드는지

**목적**: 격리수준 이전에 “커밋 단위”가 스냅샷을 깨는지 보여주기.

실행(안전: `bench_orders`만 사용):

```bash
bash tools/run_chunk_demo.sh 10000
```

## 7) (가설 B 강화) RR 장시간 스냅샷이 undo/purge(History list length)를 악화시키는지

**목적**: “오래 열린 RR 스냅샷이 purge를 막아서 undo backlog가 쌓이는지”를 시계열(TSV)로 캡처.

실행 예시:

```bash
bash tools/run_undo_history_len_bench.sh 60 60 4 20000 1 1000000 2 30
```

출력/파일:

- `out/undo_history_*.tsv`에 phase별 시계열 저장
- 요약표의 `max_trx_rseg_history_len`이 `rr_snapshot`에서 baseline보다 크게 뜨면 “MySQL스럽게 증명”된 것

## 핵심 스크립트 목록(원본 파일)

- 범위 집계 배치/OLTP: `experiments/20_agg_snapshot/agg_range_demo_batch.sql`, `experiments/20_agg_snapshot/agg_range_demo_oltp.sql`
- 락/데드락 벤치: `tools/run_isolation_lockbench_nodrop.sh`, `experiments/30_lockbench/ps_report.sql`, `experiments/30_lockbench/grant_perf_schema.sql`
- 범위 크기 스윕: `tools/run_orders_range_sweep.sh`
- gap/next-key 벤치: `tools/run_gaplock_bench_nodrop.sh`
- 큐 클레임 벤치: `tools/run_queue_claim_bench_nodrop.sh`, `experiments/10_queue_claim/bench_queue_tables.sql`
- chunk mixed snapshot 데모: `tools/run_chunk_demo.sh`, `tools/run_chunk_demo_bench.sh`, `experiments/50_chunk_demo/bench_orders_tables.sql`
- undo/purge 캡처: `tools/run_undo_history_len_bench.sh`, `experiments/60_undo_purge/undo_report.sql`
