# db-tx-batch

목표/범위(1문장): 배치가 읽고 계산하고 쓰는 동안 동시 OLTP 트래픽이 들어오면, 격리수준별로 어떤 이상현상(중복 처리/누락/잘못된 합산/충돌·대기)이 생기는지 재현하고 수치화한다.

## Quickstart (MySQL)

```bash
docker compose up -d
source ./env.sh
```

핵심 실험 러너/가이드는 `RUNBOOK.md`에 

스키마/데이터 준비:

```bash
mysql_lab < experiments/00_setup/settings.sql
mysql_lab < experiments/00_setup/set_queue.sql
# (집계 실험도 하려면) mysql_lab < experiments/00_setup/set_order.sql
```

현재 DB 세팅 캡처:

```bash
mysql_lab < experiments/00_setup/capture_mysql_settings.sql
```

## 큐 기반 배치: 나쁜 패턴 vs 좋은 패턴

### 1) 나쁜 패턴(레이스) 재현

리셋:

```bash
mysql_lab < experiments/10_queue_claim/reset_job1.sql
```

터미널 A:

```bash
mysql_lab < experiments/10_queue_claim/bad_a.sql
```

터미널 B(반드시 A가 SLEEP 중일 때 실행):

```bash
mysql_lab < experiments/10_queue_claim/bad_b.sql
```

결과:

```bash
mysql_lab < experiments/10_queue_claim/check.sql
```

기대 관찰: `bad_b.sql`에서 `Duplicate entry 'job-1' for key 'PRIMARY'` (중복 작업 시도 “증거”).

### 2) 좋은 패턴(FOR UPDATE SKIP LOCKED) 재현

리셋:

```bash
mysql_lab < experiments/10_queue_claim/reset_job12.sql
```

터미널 A:

```bash
mysql_lab < experiments/10_queue_claim/good_a.sql
```

터미널 B(A가 SLEEP 중일 때 실행):

```bash
mysql_lab < experiments/10_queue_claim/good_b.sql
```

결과:

```bash
mysql_lab < experiments/10_queue_claim/check12.sql
```

기대 관찰: A/B가 서로 다른 job(1,2)를 각각 클레임하고, `processed_log`에 `job-1`, `job-2`가 각 1개씩만 남음.

## 대용량 데이터(수천만~수억) 생성

> 주의: 수억 건은 디스크/시간이 크게 듭니다. 먼저 `tools/table_stats.sql`로 용량을 보면서 단계적으로 키우세요.

시퀀스 유틸(1..1,000,000) 준비:

```bash
mysql_lab < tools/bootstrap_sequences.sql
```

orders N건 시드(기본 1,000,000건, 1,000,000씩 반복 삽입):

```bash
./tools/seed_orders_large.sh 1000000 1000000 30
```

work_queue M건 시드:

```bash
./tools/seed_work_queue_large.sh 2000000 1000000
```

테이블 용량/추정 행수 확인:

```bash
mysql_lab < tools/table_stats.sql
```
