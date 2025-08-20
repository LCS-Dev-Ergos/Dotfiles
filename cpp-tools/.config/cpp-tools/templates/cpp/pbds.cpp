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
  #include "../Algorithms/debug.h"
#else
  #define debug(...) 42
#endif
// clang-format on
// Type aliases
using ll   = long long;
using vi   = vector<int>;
using pii  = pair<int, int>;
using vll  = vector<ll>;
using vpii = vector<pii>;

// ----- PBDS Typedefs ----- //
// Ordered Set (for unique elements)
template <typename T>
using ordered_set = tree<T, null_type, less<T>, rb_tree_tag, tree_order_statistics_node_update>;

// Ordered Multiset (for duplicate elements)
template <typename T>
using ordered_multiset = tree<T, null_type, less_equal<T>, rb_tree_tag, tree_order_statistics_node_update>;

// Constants
constexpr int MOD  = 1e9 + 7;
constexpr int INF  = 1e9;
constexpr ll  LINF = 1e18;

//===----------------------------------------------------------------------===//
/* Data Types and Function Definitions */

// Function to solve a single test case
void solve() {
  // Your solution here
}

//===----------------------------------------------------------------------===//
//  Main Function
//===----------------------------------------------------------------------===//

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