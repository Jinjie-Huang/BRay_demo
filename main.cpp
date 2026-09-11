#include <iostream>

namespace bray_demo {
int handle_request(int request);
}

int main() {
  int checksum = 0;
  for (int request = 1; request <= 3; ++request)
    checksum += bray_demo::handle_request(request);
  std::cout << "checksum=" << checksum << '\n';
  return 0;
}
