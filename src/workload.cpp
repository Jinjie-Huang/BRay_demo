#include <chrono>
#include <cstdint>
#include <thread>

namespace bray_demo {

__attribute__((noinline)) int parse_request(int request) {
  std::this_thread::sleep_for(std::chrono::milliseconds(2));
  return request * 3 + 1;
}

__attribute__((noinline)) int compute_score(int value) {
  std::this_thread::sleep_for(std::chrono::milliseconds(4));
  volatile std::uint64_t accumulator = 0;
  for (std::uint64_t index = 0; index < 10000; ++index)
    accumulator += (index ^ static_cast<std::uint64_t>(value)) & 0xff;
  return value + static_cast<int>(accumulator & 7);
}

__attribute__((noinline)) int persist_result(int value) {
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  return value;
}

__attribute__((noinline)) int run_pipeline(int request) {
  int parsed = parse_request(request);
  int score = compute_score(parsed);
  return persist_result(score);
}

__attribute__((noinline, visibility("default"))) int
handle_request(int request) {
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  return run_pipeline(request);
}

} // namespace bray_demo
