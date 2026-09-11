#include <cxxabi.h>
#include <dlfcn.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Frame {
  std::uint64_t FunctionPC;
  std::uint64_t StartNs;
  std::uint64_t ChildNs;
  std::string Name;
};

struct Event {
  std::uint64_t FunctionPC;
  std::uint64_t StartNs;
  std::uint64_t DurationNs;
  std::uint64_t ExclusiveNs;
  long ThreadId;
  std::size_t Depth;
  std::string Name;
};

thread_local std::vector<Frame> CallStack;
thread_local bool InsideHook;

std::uint64_t nowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             Clock::now().time_since_epoch())
      .count();
}

long getThreadId() { return static_cast<long>(syscall(SYS_gettid)); }

std::string escapeJson(const std::string &Value) {
  std::ostringstream Escaped;
  for (unsigned char Character : Value) {
    switch (Character) {
    case '"':
      Escaped << "\\\"";
      break;
    case '\\':
      Escaped << "\\\\";
      break;
    case '\b':
      Escaped << "\\b";
      break;
    case '\f':
      Escaped << "\\f";
      break;
    case '\n':
      Escaped << "\\n";
      break;
    case '\r':
      Escaped << "\\r";
      break;
    case '\t':
      Escaped << "\\t";
      break;
    default:
      if (Character < 0x20)
        Escaped << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                << static_cast<unsigned>(Character);
      else
        Escaped << Character;
    }
  }
  return Escaped.str();
}

std::string resolveName(std::uint64_t FunctionPC) {
  Dl_info Info{};
  if (dladdr(reinterpret_cast<void *>(FunctionPC), &Info) && Info.dli_sname) {
    int Status = 0;
    char *Demangled =
        abi::__cxa_demangle(Info.dli_sname, nullptr, nullptr, &Status);
    if (Status == 0 && Demangled) {
      std::string Name(Demangled);
      std::free(Demangled);
      return Name;
    }
    std::free(Demangled);
    return Info.dli_sname;
  }

  std::ostringstream Name;
  Name << "0x" << std::hex << FunctionPC;
  return Name.str();
}

class Trace {
public:
  Trace()
      : OutputPath([] {
          const char *Path = std::getenv("BRAY_TRACE_FILE");
          return Path && *Path ? std::string(Path)
                               : std::string("bray-trace.json");
        }()),
        ProcessId(getpid()) {}

  ~Trace() {
    try {
      write();
    } catch (...) {
      std::cerr << "[BRay] failed to write " << OutputPath << '\n';
    }
  }

  void add(Event NewEvent) {
    std::lock_guard<std::mutex> Guard(Lock);
    Events.emplace_back(std::move(NewEvent));
  }

private:
  void write() {
    std::lock_guard<std::mutex> Guard(Lock);
    std::sort(Events.begin(), Events.end(), [](const Event &Left,
                                               const Event &Right) {
      if (Left.StartNs != Right.StartNs)
        return Left.StartNs < Right.StartNs;
      return Left.DurationNs > Right.DurationNs;
    });

    std::ofstream Output(OutputPath);
    if (!Output)
      return;

    std::set<long> ThreadIds;
    for (const Event &Current : Events)
      ThreadIds.insert(Current.ThreadId);
    const std::uint64_t BaseNs = Events.empty() ? 0 : Events.front().StartNs;

    bool First = true;
    auto beginEvent = [&] {
      if (!First)
        Output << ",\n";
      First = false;
      Output << "    ";
    };

    Output << "{\n  \"displayTimeUnit\": \"ms\",\n  \"traceEvents\": [\n";
    beginEvent();
    Output << "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":"
           << ProcessId
           << ",\"tid\":0,\"args\":{\"name\":\"BRay demo\"}}";

    for (long ThreadId : ThreadIds) {
      beginEvent();
      Output << "{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":"
             << ProcessId << ",\"tid\":" << ThreadId
             << ",\"args\":{\"name\":\"thread " << ThreadId << "\"}}";
    }

    for (const Event &Current : Events) {
      beginEvent();
      Output << "{\"name\":\"" << escapeJson(Current.Name)
             << "\",\"cat\":\"BRay\",\"ph\":\"X\",\"pid\":"
             << ProcessId << ",\"tid\":" << Current.ThreadId
             << ",\"ts\":" << (Current.StartNs - BaseNs) / 1000
             << ",\"dur\":" << Current.DurationNs / 1000
             << ",\"args\":{\"function_pc\":\"0x" << std::hex
             << Current.FunctionPC << std::dec
             << "\",\"exclusive_us\":" << Current.ExclusiveNs / 1000
             << "}}";
    }

    Output << "\n  ]\n}\n";
    std::cerr << "[BRay] call tree (inclusive / self):\n";
    for (const Event &Current : Events) {
      std::ostringstream Line;
      Line << "[BRay] " << std::string(Current.Depth * 2, ' ')
           << Current.Name << ' ' << std::fixed << std::setprecision(3)
           << Current.DurationNs / 1000000.0 << " ms / "
           << Current.ExclusiveNs / 1000000.0 << " ms\n";
      std::cerr << Line.str();
    }
    std::cerr << "[BRay] wrote " << Events.size() << " function events to "
              << OutputPath << '\n';
  }

  std::string OutputPath;
  pid_t ProcessId;
  std::mutex Lock;
  std::vector<Event> Events;
};

Trace &trace() {
  static Trace Instance;
  return Instance;
}

class HookGuard {
public:
  HookGuard() : Active(!InsideHook) {
    if (Active)
      InsideHook = true;
  }

  ~HookGuard() {
    if (Active)
      InsideHook = false;
  }

  explicit operator bool() const { return Active; }

private:
  bool Active;
};

} // namespace

extern "C" __attribute__((visibility("default"))) void
__bolt_probe_enter(std::uint64_t FunctionPC) noexcept {
  HookGuard Guard;
  if (!Guard)
    return;

  try {
    CallStack.push_back(
        Frame{FunctionPC, nowNs(), 0, resolveName(FunctionPC)});
  } catch (...) {
  }
}

extern "C" __attribute__((visibility("default"))) void
__bolt_probe_exit(std::uint64_t FunctionPC) noexcept {
  HookGuard Guard;
  if (!Guard || CallStack.empty())
    return;

  try {
    const std::uint64_t EndNs = nowNs();
    Frame Current = std::move(CallStack.back());
    CallStack.pop_back();
    if (Current.FunctionPC != FunctionPC)
      return;

    const std::uint64_t DurationNs = EndNs - Current.StartNs;
    const std::uint64_t ExclusiveNs =
        DurationNs > Current.ChildNs ? DurationNs - Current.ChildNs : 0;
    if (!CallStack.empty())
      CallStack.back().ChildNs += DurationNs;

    trace().add(Event{FunctionPC, Current.StartNs, DurationNs, ExclusiveNs,
                      getThreadId(), CallStack.size(),
                      std::move(Current.Name)});
  } catch (...) {
  }
}
