이 글에서는 배치가 읽고 계산하고 쓰는 동안 동시 OLTP 트래픽이 들어오면, 격리수준별로 어떤 이상현상(중복 처리, 누락 처리, 잘못된 합산, 충돌·대기)이 발생하는지를 재현하고 수치화한다.

## 실험 환경

- MySQL 8.0.36 (docker)
- `orders` 약 2.1억건(최대 id 기준 `209,663,440`)
- `autocommit=1` (하지만 실험은 `START TRANSACTION`으로 명시적 트랜잭션)
- 기본 격리수준: `REPEATABLE-READ`
- `innodb_lock_wait_timeout=5`

## 보고서: 가설 A/B/C/D 결과 및 해석

본 절은 동일한 실험들을 “가설(A~D) 단위”로 재정리하고, 관측된 수치가 어떤 메커니즘에서 기인하는지 설명한다. 아래에 이어지는 “케이스 1~”은 실행 캡처(로그)로서 증빙 역할을 한다.

실험 범위는 다음 1문장으로 고정한다. 배치가 읽고 계산하고 쓰는 동안 동시 OLTP 트래픽이 들어오면, 격리수준별로 어떤 이상현상(중복 처리, 누락 처리, 잘못된 합산, 충돌·대기)이 발생하는지를 재현하고 수치화한다.

실험에서의 “배치”는 두 가지 형태를 사용한다. 첫째, 집계형 배치로서 원천(orders)을 범위로 읽어 합계를 계산한다. 둘째, 상태전이형 배치로서 READY 작업을 선점(claim)하여 PROCESSING/DONE으로 전이시키는 큐 소비 패턴을 사용한다. OLTP는 집계형 배치에는 동일 범위를 업데이트하여 경합을 유발하고, 큐 배치에는 다중 워커 경쟁으로 중복/데드락 가능성을 유발한다.

### 가설 A: READ COMMITTED에서 집계 배치 결과가 흔들리고, 스냅샷이 없으면 diff가 커진다

가설 A는 MySQL InnoDB의 READ COMMITTED가 “statement 단위”로 커밋된 최신 버전을 보기 쉽다는 점에서 출발한다. 동일 트랜잭션이라도 두 번의 SELECT는 서로 다른 read view를 사용할 수 있으므로, 배치가 동일 범위를 두 번 집계하는 사이에 OLTP 커밋이 발생하면 두 번째 집계가 그 변화를 반영하여 합계가 달라질 수 있다. 이 현상은 row 단위로 amount를 +1 업데이트하는 부하를 넣었을 때 특히 선명해진다. 집계 diff가 “업데이트된 행 수”와 같은 크기(또는 그에 비례)로 나타나는 경향이 생기기 때문이다.

다음 표는 범위 크기를 증가시키며 관측한 결과이다. READ COMMITTED에서는 범위가 커질수록 batch_sum_diff가 증가하는데, 이는 배치가 같은 범위를 두 번 읽는 동안 OLTP가 커밋한 row 수가 늘어나기 때문이다. 반면 REPEATABLE READ에서는 동일 트랜잭션 내에서 consistent read 스냅샷을 유지하는 방향으로 동작하여 batch_sum_diff가 0으로 유지된다.

| range_size | isolation | lo_id | hi_id | wall_s | batch_sum_diff | oltp_rows_updated | oltp_waited_ms | oltp_status | deadlocks_delta | lock_wait_timeouts_delta |
|---:|---|---:|---:|---:|---:|---:|---:|---|---:|---:|
| 100000 | READ COMMITTED | 1 | 100000 | 3 | 80000.000000000000000000000000000000 | 80000 | 398.5330 | OK | 0 | 0 |
| 100000 | REPEATABLE READ | 1 | 100000 | 2 | 0.000000000000000000000000000000 | 80000 | 364.4230 | OK | 0 | 0 |
| 1000000 | READ COMMITTED | 1 | 1000000 | 6 | 800000.000000000000000000000000000000 | 800000 | 3314.6630 | OK | 0 | 0 |
| 1000000 | REPEATABLE READ | 1 | 1000000 | 6 | 0.000000000000000000000000000000 | 800000 | 3383.5090 | OK | 0 | 0 |
| 10000000 | READ COMMITTED | 1 | 10000000 | 39 | 7650368.000000000000000000000000000000 | 7650368 | 32659.9040 | OK | 0 | 0 |
| 10000000 | REPEATABLE READ | 1 | 10000000 | 43 | 0.000000000000000000000000000000 | 7650368 | 32013.3720 | OK | 0 | 0 |
| 10000000 | SERIALIZABLE | 1 | 10000000 | 46 | 0.000000000000000000000000000000 | 7650368 | 39120.5250 | OK | 0 | 0 |
| 50000000 | READ COMMITTED | 1 | 50000000 | 197 | 38174144.000000000000000000000000000000 | 38174144 | 167867.2940 | OK | 0 | 0 |
| 50000000 | REPEATABLE READ | 1 | 50000000 | 215 | 0.000000000000000000000000000000 | 38174144 | 165694.0060 | OK | 0 | 0 |
| 50000000 | SERIALIZABLE | 1 | 50000000 | 48 | 0.000000000000000000000000000000 | NA | NA | 1205 | 0 | 1 |

추가로, 가설 A는 격리수준뿐 아니라 배치의 커밋 단위에서도 강화된다. 동일 배치를 chunk 단위로 끊어 여러 트랜잭션으로 읽고 합산하면, 각 chunk가 서로 다른 시점의 스냅샷을 읽어 “혼합 스냅샷(mixed snapshot)” 결과가 만들어질 수 있다. 이는 READ COMMITTED와 같은 격리수준에서 더 자주 드러나지만, 근본 원인은 격리수준이 아니라 배치 설계(트랜잭션 경계) 자체에 있다. chunk 사이에 OLTP가 전체 행을 +1 업데이트하면, 앞 chunk는 업데이트 전, 뒤 chunk는 업데이트 후를 읽게 되어 단일 배치 결과가 일관된 시점의 값이 되지 않는다. 본 실험의 bench_orders 데모에서는 mixed_total=1,005,000인 반면, 업데이트 이후 단일 시점에서 계산한 truth_sum=1,010,000으로 diff=-5,000이 관측되었다.

### 가설 B: REPEATABLE READ는 읽기 일관성은 좋으나, 장시간 트랜잭션에서 범위 경합과 purge 지연 비용이 커진다

가설 B는 두 개의 이유로 비용이 발생한다. 첫째, 범위/인덱스 기반의 락 패턴에서 REPEATABLE READ 및 SERIALIZABLE은 gap/next-key 락으로 인해 삽입/갱신이 대기하게 만드는 경향이 있다. 둘째, 장시간 스냅샷이 유지되면 purge가 과거 버전을 정리하지 못해 undo backlog가 쌓인다. 이는 시간이 지남에 따라 메모리/IO 압박과 응답시간 악화로 이어질 수 있다.

범위 경합은 작은 벤치 테이블에서 다음과 같이 수치로 재현되었다. 동일한 범위를 FOR UPDATE로 잡아두는 동안, 그 구간에 INSERT를 시도하면 READ COMMITTED는 거의 즉시 완료되는 반면 REPEATABLE READ 및 SERIALIZABLE에서는 보유 시간(hold_seconds)에 근접한 대기 시간이 발생한다. 이는 “격리수준을 올리면 정합성은 강화되지만, 범위 경합의 비용이 증가한다”는 방향을 직접적으로 보여준다.

| isolation | inserter_waited_ms | ps_row_lock_waits_during | ps_max_wait_age_secs_during | deadlocks_delta | lock_wait_timeouts_delta |
|---|---:|---:|---:|---:|---:|
| READ COMMITTED | 11.1370 | 0 | 0 | 0 | 0 |
| REPEATABLE READ | 4659.6510 | 1 | 1 | 0 | 0 |
| SERIALIZABLE | 4668.1340 | 1 | 1 | 0 | 0 |

장시간 스냅샷 비용은 undo/purge 관측으로 재현하였다. long snapshot 없이 동일한 업데이트 부하를 수행한 baseline 대비, REPEATABLE READ 스냅샷을 의도적으로 오래 유지한 rr_snapshot 구간에서 trx_rseg_history_len이 크게 상승하였다. 해당 값은 purge가 정리하지 못한 history(undo) 누적량과 연관된 지표로 해석할 수 있으며, 운영 환경에서는 이 값이 지속적으로 높게 유지될 경우 성능 저하로 전이될 수 있다.

| phase | max_innodb_history_list_length | max_trx_rseg_history_len |
|---|---:|---:|
| baseline (no long snapshot) | 0 | 37 |
| rr_snapshot (long RR tx held) | 0 | 522 |
| cooldown (after snapshot commit) | 0 | 548 |

본 환경에서는 Innodb_history_list_length가 NULL로 관측되어 요약 표에서는 0으로 나타났으므로, 판단은 trx_rseg_history_len을 우선 지표로 삼았다. 또한 cooldown 구간의 최대값이 rr_snapshot보다 크게 보이는 것은 “커밋 직후 purge가 아직 따라잡기 전” 구간이 포함되었기 때문이다. 상세 시계열은 out/undo_history_*.tsv에 저장된다.

### 가설 C: SERIALIZABLE은 정합성은 강하지만, 충돌·대기로 인한 실패(타임아웃) 및 재시도 비용이 증가한다

가설 C는 SERIALIZABLE을 적용했을 때 “읽기 자체가 쓰기를 막는 형태” 또는 그 반대가 되어 동시성이 감소하고, 결과적으로 대기/타임아웃/데드락 및 재시도 요구가 증가한다는 주장이다. 소규모 벤치(2-row)에서는 격리수준에 따른 차이가 크게 드러나지 않을 수 있으며, 이는 락 순서(lock ordering)가 데드락을 결정하는 경우가 많고, 락 대기 또한 시나리오가 고정되어 있기 때문이다. 그럼에도 performance_schema 기반의 델타 측정을 통해 락 대기 및 데드락이 재현됨을 확인할 수 있었다.

| isolation | lockwait_waited_ms | deadlocks_delta | lock_wait_timeouts_delta |
|---|---:|---:|---:|
| READ COMMITTED | 4609.4670 | 1 | 0 |
| REPEATABLE READ | 4659.2530 | 1 | 0 |
| SERIALIZABLE | 4675.1040 | 1 | 0 |

SERIALIZABLE의 운영 비용은 대용량 범위에서 보다 직접적으로 관측되었다. id 1..50,000,000 범위에서 배치가 SERIALIZABLE로 읽는 동안 동일 범위를 업데이트하는 OLTP 트랜잭션이 ER_LOCK_WAIT_TIMEOUT(1205)로 실패하였다. 이는 innodb_lock_wait_timeout=5 설정으로 인해 타임아웃이 빠르게 발생하도록 구성된 점의 영향도 있으나, 보다 근본적으로는 “큰 충돌 면적에서 SERIALIZABLE이 동시 쓰기를 실패로 밀어낼 수 있다”는 것을 보여준다. 운영 설계 관점에서는 SERIALIZABLE을 단독 해법으로 보기보다는, 범위 축소, 배치 트랜잭션 짧게 유지, 재시도 정책, 충돌면적을 줄이는 설계(워터마크, 스냅샷 테이블, 파티셔닝 등)와 결합해야 한다.

### 가설 D: 격리수준보다 설계 패턴이 먼저이며, 중복/누락은 클레임 및 멱등 설계로 제어할 수 있다

가설 D는 “정합성의 상당 부분은 격리수준을 올려서가 아니라, 경쟁 조건을 제거하는 패턴으로 해결할 수 있다”는 주장이다. 큐 소비 시나리오에서 가장 중요한 것은 READY 작업을 어떻게 선점(claim)하느냐이며, 단순 SELECT 후 외부작업(또는 sleep)으로 레이스 창을 열면 격리수준과 무관하게 중복 시도가 발생할 수 있다. 반면 SELECT FOR UPDATE SKIP LOCKED로 선점한 뒤 처리하면 다중 워커 환경에서도 중복 시도 자체가 감소한다. 또한 processed_log의 unique 제약은 “중복 처리 시도”의 탐지에는 유용하지만, 외부 부작용(결제, 메시지 발송 등)을 완전히 막는 장치가 되지는 못하므로 선점 패턴과 함께 사용되어야 한다.

다음 표는 워커 8개, 20초, seed_jobs=50,000 조건에서 good(선점)과 bad(레이스) 패턴을 비교한 것이다. READ COMMITTED/REPEATABLE READ에서 bad 패턴은 1062(duplicate) 오류가 급증하고 처리량이 급감하였다. SERIALIZABLE에서는 bad 패턴에서 1062는 0으로 보이지만, 대신 데드락이 대량 발생하여 운영 비용이 다른 형태로 전환되었다. 즉, 격리수준 상승이 중복 시도 자체를 제거하는 “설계”를 대체하지 못하며, 경우에 따라서는 실패 모드만 바꾸는 결과가 된다.

| mode | isolation | DONE | READY | done_per_sec | duplicate_errors(1062) | deadlocks |
|---|---|---:|---:|---:|---:|---:|
| good | READ COMMITTED | 876 | 49124 | 43.80 | 0 | 0 |
| bad | READ COMMITTED | 163 | 49837 | 8.15 | 728 | 0 |
| good | REPEATABLE READ | 849 | 49151 | 42.45 | 0 | 0 |
| bad | REPEATABLE READ | 150 | 49850 | 7.50 | 749 | 0 |
| good | SERIALIZABLE | 784 | 49216 | 39.20 | 0 | 0 |
| bad | SERIALIZABLE | 107 | 49893 | 5.35 | 0 | 733 |

종합하면, 집계형 배치에서는 “일관된 스냅샷을 확보하는 방식”과 “충돌 면적을 줄이는 설계”가 핵심이며, 상태전이형 배치에서는 “선점(claim) + SKIP LOCKED + 멱등키” 조합이 핵심이다. 격리수준은 이 설계들을 보완하는 도구이며, 단독으로 정합성과 운영성을 동시에 만족시키는 만능 해법으로 보기 어렵다.

## 케이스 1) 나쁜 패턴 재현 (SELECT → SLEEP → 처리)

> 동시 실행 타이밍이 흔들리지 않게 하기 위해, `experiments/10_queue_claim/bad_a.sql`/`experiments/10_queue_claim/bad_b.sql`에 `GET_LOCK('bad_claim_demo', ...)` barrier와 pre-sleep(8s)을 추가해 **결정적으로** 재현되게 해둠.

리셋:

```bash
mysql_lab < experiments/10_queue_claim/reset_job1.sql
```

터미널 A:

```bash
mysql_lab < experiments/10_queue_claim/bad_a.sql
```

캡처(A 출력):

```text
1
A_SELECTED	1	job-1
A_DONE
```

터미널 B (A 실행 중):

```bash
mysql_lab < experiments/10_queue_claim/bad_b.sql
```

캡처(B 출력):

```text
1
B_SELECTED	1	job-1
--------------
INSERT INTO processed_log(dedupe_key, processed_at)
VALUES (@payload, NOW())
--------------

ERROR 1062 (23000) at line 26: Duplicate entry 'job-1' for key 'processed_log.PRIMARY'
```

결과 확인:

```bash
mysql_lab < experiments/10_queue_claim/check.sql
```

캡처(check 출력):

```text
1	DONE	batchA	NULL	2026-02-22 08:07:03
job-1	2026-02-22 08:07:03
```

관찰:

- B가 **같은 job-1을 처리 시도**했고, `processed_log`의 PK(`dedupe_key`) 유니크 충돌로 터졌다 → “나쁜 클레임 패턴이면 중복 작업 시도가 발생”의 증거.
- `work_queue.id=1`의 최종 owner는 `batchA`로 남는다(누가 먼저 커밋했는지 반영).

## 케이스 2) 좋은 패턴 재현 (FOR UPDATE SKIP LOCKED로 클레임)

> 마찬가지로 결정적 재현을 위해 `experiments/10_queue_claim/good_a.sql`/`experiments/10_queue_claim/good_b.sql`에 `GET_LOCK('good_claim_demo', ...)` barrier + pre-sleep(8s)을 추가.

리셋:

```bash
mysql_lab < experiments/10_queue_claim/reset_job12.sql
```

터미널 A:

```bash
mysql_lab < experiments/10_queue_claim/good_a.sql
```

캡처(A 출력):

```text
1
A_CLAIMED	1	job-1
A_DONE
```

터미널 B (A 실행 중):

```bash
mysql_lab < experiments/10_queue_claim/good_b.sql
```

캡처(B 출력):

```text
1
B_CLAIMED	2	job-2
B_DONE
```

결과 확인:

```bash
mysql_lab < experiments/10_queue_claim/check12.sql
```

캡처(check12 출력):

```text
1	DONE	batchA	NULL	2026-02-22 08:08:11
2	DONE	batchB	NULL	2026-02-22 08:08:07
job-1	2026-02-22 08:08:11
job-2	2026-02-22 08:08:07
```

관찰:

- A가 `id=1`을 `FOR UPDATE ... SKIP LOCKED`로 잡아두는 동안, B는 대기/충돌 없이 `id=2`를 클레임했다.
- `processed_log`에 `job-1`, `job-2`가 각각 1개씩만 남아 중복 시도 자체가 사라졌다.

## 케이스 3) 집계 배치 RC vs RR 차이 재현 (non-repeatable read)

의도:

- 같은 배치 트랜잭션 안에서 `SUM(amount)`를 2번 읽는 동안, OLTP가 중간에 `amount = amount + 1` 업데이트를 커밋하면
  - **READ COMMITTED**: 1차/2차 합계가 달라질 수 있음(non-repeatable read)
  - **REPEATABLE READ**: 트랜잭션 스냅샷으로 1차/2차 합계가 동일(동일 트랜잭션 안에서는 일관)

참고:

- 예전에 쓰던 `tools/run_agg_rc_rr_demo.sh`는 **drop/recreate를 유발**해서 삭제했습니다.
- 현재 재현은 **no-drop 범위 집계 러너**로 합니다: `bash tools/run_agg_range_rc_rr_nodrop.sh 1 100000`

캡처(legacy, 2026-02-22T08:23:45Z; 개념 설명용):

```text
# agg_rc_rr_demo 2026-02-22T08:23:45Z

## Aggregation demo: READ COMMITTED

Batch output:
1
BATCH_SUM_1	READ COMMITTED	1000000
BATCH_SUM_2	READ COMMITTED	1010000
BATCH_DIFF	READ COMMITTED	10000.000000000000000000000000000000

OLTP output:
1
OLTP_UPDATED	10000

agg_total:
ALL	1010000	10000	2026-02-22 08:23:53

## Aggregation demo: REPEATABLE READ

Batch output:
1
BATCH_SUM_1	REPEATABLE READ	1000000
BATCH_SUM_2	REPEATABLE READ	1000000
BATCH_DIFF	REPEATABLE READ	0.000000000000000000000000000000

OLTP output:
1
OLTP_UPDATED	10000

agg_total:
ALL	1000000	10000	2026-02-22 08:24:00
```

관찰:

- RC에서는 배치가 1차 SUM 이후 OLTP 커밋을 “보게” 되어 `BATCH_DIFF=10000`이 발생했다.
- RR에서는 같은 트랜잭션 내에서 스냅샷을 유지해 `BATCH_DIFF=0`이 나왔다(배치 중간 커밋 반영이 안 됨).

## 케이스 4) RC vs RR vs SERIALIZABLE 락 대기/데드락 수치화 (performance_schema 포함)

의도:

- 격리수준 3종(RC/RR/SERIALIZABLE)에서
  - **락 대기(wait)**: “대기 시간(ms)” + “대기 발생 여부(PS에서 관측되는지)”
  - **데드락(deadlock)**: `ER_LOCK_DEADLOCK` 누적 카운터(before/after diff)
를 숫자로 뽑는다.

참고:

- 예전에 쓰던 `tools/run_isolation_lockbench.sh`는 `settings.sql` 실행(테이블 drop/recreate)이 포함돼 있어서 삭제했습니다.
- 현재는 no-drop 러너(`tools/run_isolation_lockbench_nodrop.sh`)만 유지합니다. (아래 케이스 5)

캡처(legacy, 2026-02-22T08:24:06Z; 개념 설명용):

```text
# lockbench 2026-02-22T08:24:06Z

| isolation | lockwait_waited_ms | ps_row_lock_waits_during | ps_max_wait_age_secs_during | deadlocks_delta | lock_wait_timeouts_delta |
|---|---:|---:|---:|---:|---:|
| READ COMMITTED | 4649.4810 | 1 | 1 | 1 | 0 |
| REPEATABLE READ | 4667.2790 | 1 | 1 | 1 | 0 |
| SERIALIZABLE | 4661.4690 | 1 | 1 | 1 | 0 |
```

관찰/해석:

- 락 대기: holder가 약 5초 잡고 있도록 만든 시나리오라 `lockwait_waited_ms≈4.6s`로 측정되며, 동시에 `performance_schema.data_lock_waits`도 1건 관측(`ps_row_lock_waits_during=1`).
- 데드락: 반대 순서로 `id=1`/`id=2`를 업데이트하는 2세션을 동시에 실행해 1건의 데드락이 발생(`deadlocks_delta=1`). (데드락은 “정상 재현”이며, 격리수준을 바꿔도 lock ordering이 같으면 발생 가능)

## 케이스 5) RC vs RR vs SERIALIZABLE 락 대기/데드락 수치화 (no-drop bench_kv)

실행:

```bash
bash tools/run_isolation_lockbench_nodrop.sh
```

캡처(2026-02-22 11:44:51, `tools/run_isolation_lockbench_nodrop.sh` 출력):

```text
# lockbench_nodrop 2026-02-22T11:44:51Z

| isolation | lockwait_waited_ms | ps_row_lock_waits_during | ps_max_wait_age_secs_during | deadlocks_delta | lock_wait_timeouts_delta |
|---|---:|---:|---:|---:|---:|
| READ COMMITTED | 4609.4670 | 1 | 1 | 1 | 0 |
| REPEATABLE READ | 4659.2530 | 1 | 2 | 1 | 0 |
| SERIALIZABLE | 4675.1040 | 1 | 1 | 1 | 0 |
```

해석(요약):

- 이 벤치는 `orders` 같은 대용량 테이블이 아니라 `bench_kv`(2-row)만 사용하므로, “격리수준 자체 + 락 시나리오”에서 생기는 **순수한 락 대기/데드락 신호**를 빠르게 확인하는 용도다.
- 세 격리수준 모두 row lock wait가 재현되고(`lockwait_waited_ms≈4.6~4.7s`), 데드락도 1건씩 재현된다(`deadlocks_delta=1`).
- SERIALIZABLE의 비용은 이 벤치만으로 크게 갈리진 않을 수 있으니, 실제 워크로드와 유사한 범위/트랜잭션 길이에서 `waited_ms`, timeout, 처리량 지표와 함께 비교해야 한다.

## 케이스 6) 대용량 범위 집계 + 범위 업데이트: SERIALIZABLE에서 lock wait timeout 재현

실행:

```bash
bash tools/run_agg_range_rc_rr_nodrop.sh 1 50000000 "SERIALIZABLE"
```

캡처(2026-02-22 12:01:04, `tools/run_agg_range_rc_rr_nodrop.sh` 출력):

```text
# run_agg_range_rc_rr_nodrop 2026-02-22T12:01:04Z
range: lo_id=1 hi_id=50000000
only_isolation: SERIALIZABLE

Batch output:
BATCH_RANGE_1   SERIALIZABLE    1       50000000        38174144        19368316096
BATCH_RANGE_2   SERIALIZABLE    1       50000000        38174144        19368316096
BATCH_RANGE_DIFF        SERIALIZABLE    0       0.000000000000000000000000000000

OLTP output (update 실패):
ERROR 1205 (HY000) at line 24: Lock wait timeout exceeded; try restarting transaction

Exit codes: batch=0 oltp=1
```

해석(요약):

- SERIALIZABLE에서 배치가 범위 읽기를 수행하는 동안, 동일 범위를 업데이트하려는 OLTP가 `Lock wait timeout`(ER_LOCK_WAIT_TIMEOUT, 1205)으로 실패했다.
- 정합성(배치 스냅샷)은 강해졌지만, 동시 OLTP 쓰기 측면에서는 **대기/타임아웃 리스크**가 커지는 패턴으로 관찰된다(가설 C 방향).
- 이 케이스는 “Serializable은 실패/재시도가 정상”일 수 있음을 보여주며, 운영 설계에서는 (1) 범위 축소, (2) 배치 트랜잭션 짧게, (3) 재시도 정책, (4) 워터마크/스냅샷 테이블 같은 설계 패턴으로 충돌면적을 줄이는 접근을 함께 고려해야 한다.
