# GPT가 알려주는 벤치마크/프로파일링에 쓰기 좋은 도구들 (C/C++ 중심)

---

## 1) 마이크로 벤치마크 프레임워크 (코드 단위 성능 비교)

- **Google Benchmark**
  - 표준급 C++ 마이크로벤치 프레임워크. 반복/통계/리포트 지원이 탄탄함. :contentReference[oaicite:0]{index=0}
  - 링크: https://github.com/google/benchmark

- **nanobench (ankerl::nanobench)**
  - 단일 헤더 기반이라 붙이기 쉽고, 결과 출력도 깔끔함. :contentReference[oaicite:1]{index=1}
  - 링크: https://github.com/martinus/nanobench

- **Celero**
  - “벤치 작성 라이브러리” 느낌으로 시나리오/케이스 비교용으로 무난. :contentReference[oaicite:2]{index=2}
  - 링크: https://github.com/DigitalInBlue/Celero

- **Catch2 Benchmarks**
  - 테스트 코드 안에서 `BENCHMARK`로 간단히 붙일 수 있어서 빠르게 측정할 때 편함. :contentReference[oaicite:3]{index=3}
  - 링크: https://catch2.org/  
  - 문서: https://catch2-temp.readthedocs.io/en/latest/benchmarks.html

> 참고: 너 프로젝트는 “프로듀서/컨슈머 파이프라인 + backpressure + 퍼센타일”이 핵심이라  
> **마이크로벤치 프레임워크는 보조**, 메인은 **커스텀 러너(harness)**가 더 잘 맞음.

---

## 2) p95/p99 같은 tail latency 기록/요약

- **HdrHistogram (C port)**
  - tail(특히 p99, p99.9 등) 보기 좋게 히스토그램으로 누적/요약하는 데 강함. :contentReference[oaicite:4]{index=4}
  - 링크: https://github.com/HdrHistogram/HdrHistogram_c  
  - 개념/홈: https://hdrhistogram.github.io/HdrHistogram/

---

## 3) CPU/스케줄링/캐시 원인 파악용 프로파일러

- **Linux perf**
  - 샘플링 기반 프로파일링(핫스팟/카운터/트레이스) 표준 도구. :contentReference[oaicite:5]{index=5}
  - 링크: https://perfwiki.github.io/main/

- **FlameGraph (Brendan Gregg)**
  - perf 등으로 수집한 스택을 flame graph로 시각화하는 대표 툴. :contentReference[oaicite:6]{index=6}
  - 링크: https://github.com/brendangregg/FlameGraph

- **Tracy**
  - 실시간(원격) 텔레메트리 + 계측(instrumentation) + 샘플링 혼합형 프로파일러. 멀티스레드/프레임 타임/구간 측정에 강함. :contentReference[oaicite:7]{index=7}
  - 링크: https://github.com/wolfpld/tracy

- **Intel VTune Profiler**
  - 병렬/스레드/메모리 병목 분석에 강한 상용급 도구(무료로도 사용 가능 범위 있음). :contentReference[oaicite:8]{index=8}
  - 링크: https://www.intel.com/content/www/us/en/developer/tools/oneapi/vtune-profiler.html

---

## 4) 메모리/동시성 버그 잡기 (벤치 결과 신뢰도 확보)

- **Valgrind (Memcheck/Callgrind/Cachegrind 등)**
  - 메모리 오류, 캐시/콜 그래프 기반 프로파일링까지. 속도는 느리지만 “정확성 검증”에 좋음. :contentReference[oaicite:9]{index=9}
  - 링크: https://valgrind.org/

- **Sanitizers (ASan/TSan/UBSan 등)**
  - AddressSanitizer: 메모리 오류 탐지 :contentReference[oaicite:10]{index=10}  
  - ThreadSanitizer: 데이터 레이스 탐지 :contentReference[oaicite:11]{index=11}
  - 링크(문서):  
    - ASan: https://clang.llvm.org/docs/AddressSanitizer.html  
    - TSan: https://clang.llvm.org/docs/ThreadSanitizer.html  
  - (모음) https://github.com/google/sanitizers :contentReference[oaicite:12]{index=12}


