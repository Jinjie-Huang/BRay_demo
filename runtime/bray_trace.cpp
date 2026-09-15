// SPDX-License-Identifier: Apache-2.0

#include <limits.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Frame {
  std::uint64_t FunctionPC;
  std::uint64_t StartNs;
  std::uint64_t ChildNs;
};

struct RawEvent {
  std::uint64_t FunctionPC;
  std::uint64_t StartNs;
  std::uint64_t DurationNs;
  std::uint64_t ExclusiveNs;
  long ThreadId;
  std::size_t Depth;
};

thread_local std::vector<Frame> *CallStack;
thread_local bool InsideHook;
std::atomic<bool> Recording{true};

std::vector<Frame> &callStack() {
  if (!CallStack)
    CallStack = new std::vector<Frame>();
  return *CallStack;
}

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

struct ModuleInfo {
  std::string Path;
  std::uint64_t Base;
};

struct ModuleRange {
  std::uint64_t Start;
  std::uint64_t End;
  ModuleInfo Module;
};

std::string canonicalPath(const char *Path) {
  char Resolved[PATH_MAX];
  if (Path && *Path && realpath(Path, Resolved))
    return Resolved;

  const ssize_t Size = readlink("/proc/self/exe", Resolved, sizeof(Resolved) - 1);
  if ((!Path || !*Path) && Size > 0) {
    Resolved[Size] = '\0';
    return Resolved;
  }

  return Path ? Path : "";
}

std::vector<ModuleRange> loadModuleRanges() {
  std::ifstream Maps("/proc/self/maps");
  std::vector<ModuleRange> Ranges;
  std::string Line;
  while (std::getline(Maps, Line)) {
    std::istringstream Fields(Line);
    std::string AddressRange;
    std::string Permissions;
    std::string OffsetText;
    std::string Device;
    std::string Inode;
    if (!(Fields >> AddressRange >> Permissions >> OffsetText >> Device >>
          Inode))
      continue;

    std::string Path;
    std::getline(Fields, Path);
    const std::size_t FirstCharacter = Path.find_first_not_of(' ');
    if (FirstCharacter == std::string::npos || Path[FirstCharacter] == '[')
      continue;
    Path.erase(0, FirstCharacter);
    static const std::string DeletedSuffix = " (deleted)";
    if (Path.size() >= DeletedSuffix.size() &&
        Path.compare(Path.size() - DeletedSuffix.size(), DeletedSuffix.size(),
                     DeletedSuffix) == 0)
      Path.resize(Path.size() - DeletedSuffix.size());

    const std::size_t Separator = AddressRange.find('-');
    if (Separator == std::string::npos)
      continue;

    const std::uint64_t Start =
        std::stoull(AddressRange.substr(0, Separator), nullptr, 16);
    const std::uint64_t End =
        std::stoull(AddressRange.substr(Separator + 1), nullptr, 16);
    const std::uint64_t Offset = std::stoull(OffsetText, nullptr, 16);
    Ranges.push_back(
        ModuleRange{Start, End, {canonicalPath(Path.c_str()), Start - Offset}});
  }
  return Ranges;
}

ModuleInfo findModule(std::uint64_t FunctionPC,
                      const std::vector<ModuleRange> &Ranges) {
  for (const ModuleRange &Range : Ranges)
    if (Range.Start <= FunctionPC && FunctionPC < Range.End)
      return Range.Module;
  return {};
}

class RawTrace {
public:
  RawTrace()
      : OutputPath([] {
          const char *Path = std::getenv("BRAY_RAW_TRACE_FILE");
          return Path && *Path ? std::string(Path)
                               : std::string("bray-trace.raw.json");
        }()),
        ProcessId(getpid()), ModuleRanges(loadModuleRanges()) {}

  void add(RawEvent NewEvent) {
    std::lock_guard<std::mutex> Guard(Lock);
    if (!Modules.count(NewEvent.FunctionPC)) {
      ModuleInfo Module = findModule(NewEvent.FunctionPC, ModuleRanges);
      if (Module.Path.empty()) {
        ModuleRanges = loadModuleRanges();
        Module = findModule(NewEvent.FunctionPC, ModuleRanges);
      }
      Modules.emplace(NewEvent.FunctionPC, std::move(Module));
    }
    Events.emplace_back(NewEvent);
  }

  void write() {
    std::lock_guard<std::mutex> Guard(Lock);
    if (Written)
      return;
    Written = true;
    std::sort(Events.begin(), Events.end(), [](const RawEvent &Left,
                                               const RawEvent &Right) {
      if (Left.StartNs != Right.StartNs)
        return Left.StartNs < Right.StartNs;
      return Left.DurationNs > Right.DurationNs;
    });

    std::ofstream Output(OutputPath);
    if (!Output)
      return;

    Output << "{\n  \"pid\": " << ProcessId << ",\n  \"events\": [\n";
    for (std::size_t Index = 0; Index < Events.size(); ++Index) {
      const RawEvent &Current = Events[Index];
      const ModuleInfo &Module = Modules.at(Current.FunctionPC);
      Output << "    {\"pc\":\"0x" << std::hex << Current.FunctionPC
             << "\",\"module_base\":\"0x" << Module.Base << std::dec
             << "\",\"module\":\"" << escapeJson(Module.Path)
             << "\",\"start_ns\":" << Current.StartNs
             << ",\"duration_ns\":" << Current.DurationNs
             << ",\"exclusive_ns\":" << Current.ExclusiveNs
             << ",\"tid\":" << Current.ThreadId
             << ",\"depth\":" << Current.Depth << '}';
      if (Index + 1 != Events.size())
        Output << ',';
      Output << '\n';
    }
    Output << "  ]\n}\n";
    std::cerr << "[BRay] captured " << Events.size() << " raw function events\n";
  }

  std::string OutputPath;
  pid_t ProcessId;
  std::mutex Lock;
  std::vector<RawEvent> Events;
  std::vector<ModuleRange> ModuleRanges;
  std::unordered_map<std::uint64_t, ModuleInfo> Modules;
  bool Written{false};
};

RawTrace &trace() {
  static RawTrace *Instance = new RawTrace();
  return *Instance;
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

static void finalizeTrace() {
  Recording.store(false, std::memory_order_release);
  try {
    trace().write();
  } catch (...) {
    std::cerr << "[BRay] failed to write raw trace\n";
  }
}

__attribute__((constructor)) static void registerTraceFinalizer() {
  (void)trace();
  std::atexit(finalizeTrace);
}

extern "C" __attribute__((visibility("default"))) void
__bolt_probe_enter(std::uint64_t FunctionPC) noexcept {
  if (!Recording.load(std::memory_order_acquire))
    return;
  HookGuard Guard;
  if (!Guard)
    return;

  try {
    callStack().push_back(Frame{FunctionPC, nowNs(), 0});
  } catch (...) {
  }
}

extern "C" __attribute__((visibility("default"))) void
__bolt_probe_exit(std::uint64_t FunctionPC) noexcept {
  if (!Recording.load(std::memory_order_acquire))
    return;
  HookGuard Guard;
  if (!Guard)
    return;

  try {
    std::vector<Frame> &Stack = callStack();
    if (Stack.empty())
      return;

    const std::uint64_t EndNs = nowNs();
    Frame Current = Stack.back();
    Stack.pop_back();
    if (Current.FunctionPC != FunctionPC)
      return;

    const std::uint64_t DurationNs = EndNs - Current.StartNs;
    const std::uint64_t ExclusiveNs =
        DurationNs > Current.ChildNs ? DurationNs - Current.ChildNs : 0;
    if (!Stack.empty())
      Stack.back().ChildNs += DurationNs;

    trace().add(RawEvent{FunctionPC, Current.StartNs, DurationNs, ExclusiveNs,
                         getThreadId(), Stack.size()});
  } catch (...) {
  }
}
