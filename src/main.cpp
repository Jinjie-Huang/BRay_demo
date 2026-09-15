#include <iostream>

namespace bray_demo {
int handle_request(int request);
}

#if defined(BRAY_TEST_SHUTDOWN)
namespace {

struct ShutdownWork {
  ~ShutdownWork() { bray_demo::handle_request(0); }
};

ShutdownWork AtShutdown;

} // namespace
#endif

int main() {
  int checksum = 0;
  for (int request = 1; request <= 3; ++request)
    checksum += bray_demo::handle_request(request);
  std::cout << "checksum=" << checksum << '\n';
  return 0;
}
