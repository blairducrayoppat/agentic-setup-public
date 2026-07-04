// Dependency-free tests: <cassert> aborts (non-zero exit) on a failed assertion, which
// CTest reports as a failure. Add a framework (Catch2 / GoogleTest) later if you want one;
// this keeps the skeleton offline and zero-dependency. Extend alongside core.*.
#include <cassert>
#include "core.hpp"

int main() {
    assert(app::add(2, 3) == 5);
    assert(app::add(-1, 1) == 0);
    assert(app::add(0, 0) == 0);
    return 0;
}
