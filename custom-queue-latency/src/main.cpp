#include "harness.hpp"

#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void printUsage(const char* argv0) {
  std::cout
    << "Usage: " << argv0 << " [options]\n"
    << "\n"
    << "Options:\n"
    << "  --duration <sec>        측정 구간 길이 (기본 10)\n"
    << "  --warmup <sec>          워밍업 길이 (기본 0)\n"
    << "  --producers <n>         producer 개수 (기본 1)\n"
    << "  --consumers <n>         consumer 개수 (현재는 1만 지원)\n"
    << "  --capacity <n>          큐 용량 (기본 1024, 0이면 unbounded)\n"
    << "  --rate <eps>            producer당 초당 이벤트 수 (0이면 최대 속도)\n"
    << "  --policy <block|drop>   backpressure 정책\n"
    << "  --queue <type>          큐 타입 (현재: mutex)\n"
    << "  --help                  도움말\n";
}

bool isFlag(const std::string& s, const char* flag) {
  return s == flag;
}

std::string requireValue(int& i, int argc, char** argv, const char* flag) {
  if (i + 1 >= argc) throw std::runtime_error(std::string(flag) + " 값이 필요합니다.");
  ++i;
  return argv[i];
}

ScenarioConfig parseArgs(int argc, char** argv) {
  ScenarioConfig config{};

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (isFlag(arg, "--help") || isFlag(arg, "-h")) {
      printUsage(argv[0]);
      std::exit(0);
    }

    if (isFlag(arg, "--duration")) {
      config.duration = std::chrono::seconds(std::stoi(requireValue(i, argc, argv, "--duration")));
      continue;
    }
    if (isFlag(arg, "--warmup")) {
      config.warmup = std::chrono::seconds(std::stoi(requireValue(i, argc, argv, "--warmup")));
      continue;
    }
    if (isFlag(arg, "--producers")) {
      config.producers = std::stoi(requireValue(i, argc, argv, "--producers"));
      continue;
    }
    if (isFlag(arg, "--consumers")) {
      config.consumers = std::stoi(requireValue(i, argc, argv, "--consumers"));
      continue;
    }
    if (isFlag(arg, "--capacity")) {
      config.capacity = static_cast<std::size_t>(std::stoull(requireValue(i, argc, argv, "--capacity")));
      continue;
    }
    if (isFlag(arg, "--rate")) {
      config.rate_per_producer = std::stod(requireValue(i, argc, argv, "--rate"));
      continue;
    }
    if (isFlag(arg, "--policy")) {
      const auto v = requireValue(i, argc, argv, "--policy");
      if (v == "block") config.policy = BackpressurePolicy::Block;
      else if (v == "drop") config.policy = BackpressurePolicy::Drop;
      else throw std::runtime_error("--policy는 block 또는 drop 이어야 합니다.");
      continue;
    }
    if (isFlag(arg, "--queue")) {
      config.queue_type = requireValue(i, argc, argv, "--queue");
      continue;
    }

    throw std::runtime_error("알 수 없는 인자: " + arg);
  }

  return config;
}

void printResult(const ScenarioConfig& config, const ScenarioResult& r) {
  const auto policy_str = (config.policy == BackpressurePolicy::Block) ? "block" : "drop";
  std::cout << std::fixed << std::setprecision(2);
  std::cout << "queue=" << config.queue_type
            << " policy=" << policy_str
            << " producers=" << config.producers
            << " consumers=" << config.consumers
            << " duration_s=" << config.duration.count()
            << " warmup_s=" << config.warmup.count()
            << " capacity=" << config.capacity
            << " rate_per_producer=" << config.rate_per_producer
            << "\n";

  std::cout << "tps=" << r.tps
            << " avg_us=" << r.avg_latency_us
            << " p95_us=" << r.p95_latency_us
            << " p99_us=" << r.p99_latency_us
            << " drop=" << r.dropped
            << " produced=" << r.produced
            << " consumed=" << r.consumed
            << " samples=" << r.samples
            << "\n";
}

} // namespace

int main(int argc, char** argv) {
  try {
    const auto config = parseArgs(argc, argv);
    const auto result = runScenario(config);
    printResult(config, result);
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "Error: " << e.what() << "\n";
    printUsage(argv[0]);
    return 1;
  }
}
