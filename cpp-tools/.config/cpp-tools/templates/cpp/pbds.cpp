//===----------------------------------------------------------------------===//
/**
 * @file: __FILE_NAME__
 * @brief Codeforces Round #XXX (Div. X) - Problem Y
 * @author: Costantino Lombardi
 *
 * @status: In Progress
 */
//===----------------------------------------------------------------------===//
/* Included library */

// clang-format off
#include <bits/stdc++.h>

// Headers for Policy-Based Data Structures
#include <ext/pb_ds/assoc_container.hpp>
#include <ext/pb_ds/tree_policy.hpp>

using namespace std;
using namespace __gnu_pbds;

//===----------------------------------------------------------------------===//
/* Macros, Type Aliases, and PBDS */

// Debug macro: enabled only when LOCAL is defined
#ifdef LOCAL
  #include "debug.h"
#else
  #define debug(...) 42
#endif
// clang-format on

// Type aliases
using ll   = long long;
using ull  = unsigned long long;
using ld   = long double;
using pii  = std::pair<int, int>;
using pll  = std::pair<long long, long long>;
using vi   = std::vector<int>;
using vll  = std::vector<long long>;
using vvi  = std::vector<std::vector<int>>;
using vvll = std::vector<std::vector<long long>>;
using vs   = std::vector<std::string>;
using vpii = std::vector<std::pair<int, int>>;
using vpll = std::vector<std::pair<long long, long long>>;

// Mathematical constants
constexpr long double PI   = 3.141592653589793238462643383279502884L;
constexpr long double E    = 2.718281828459045235360287471352662498L;
constexpr long double EPS  = 1e-9L;
constexpr int         INF  = 0x3f3f3f3f;
constexpr long long   LINF = 0x3f3f3f3f3f3f3f3fLL;
constexpr int         MOD  = 1000000007;
constexpr int         MOD2 = 998244353;

// ----- PBDS Typedefs ----- //
// Ordered Set (for unique elements)
template <typename T>
using ordered_set = tree<T, null_type, less<T>, rb_tree_tag, tree_order_statistics_node_update>;

// Ordered Multiset (for duplicate elements)
template <typename T>
using ordered_multiset = tree<T, null_type, less_equal<T>, rb_tree_tag, tree_order_statistics_node_update>;

//===----------------------------------------------------------------------===//
/* Data Types and Function Definitions */

// Function to solve a single test case
void solve() {
  // Your solution here
}

//===----------------------------------------------------------------------===//
/* Main function */

int main() {
  // Fast I/O
  ios_base::sync_with_stdio(false);
  cin.tie(nullptr);

  int t = 1;
  cin >> t;
  while (t--) {
    solve();
  }

  return 0;
}

//===----------------------------------------------------------------------===//
