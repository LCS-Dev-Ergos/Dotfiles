//===----------------------------------------------------------------------===//
/**
 * @file: __FILE_NAME__
 * @brief __PROBLEM_BRIEF__
 * @author: Costantino Lombardi
 *
 * @status: In Progress
 */
//===----------------------------------------------------------------------===//
/* Included library */

// clang-format off
// Compiler optimizations:
#if defined(__GNUC__) && !defined(__clang__)
  #pragma GCC optimize("Ofast,unroll-loops,fast-math,O3")
  // Keep architecture-specific target tuning opt-in for judge portability.
  #if defined(CP_ENABLE_ARCH_TARGET_PRAGMAS) && defined(__aarch64__) && !defined(__MINGW32__) && !defined(__MINGW64__)
    #pragma GCC target("+simd")
  #endif
#endif

#ifdef __clang__
  #pragma clang optimize on
#endif

// Sanitize macro:
#ifdef USE_CLANG_SANITIZE
  #include "PCH.h"
#else
  #include <bits/stdc++.h>
#endif

// Debug macro:
#ifdef LOCAL
  #include "debug.h"
#else
  #define debug(...) 42
#endif
// clang-format on

//===----------------------------------------------------------------------===//
/* Type Aliases and Constants */

#ifndef __TYPES__
#define __TYPES__
  // Fundamental type aliases with explicit sizes:
  using I8  = std::int8_t;
  using I16 = std::int16_t;
  using I32 = std::int32_t;
  using I64 = std::int64_t;
  using U8  = std::uint8_t;
  using U16 = std::uint16_t;
  using U32 = std::uint32_t;
  using U64 = std::uint64_t;
  using F32 = float;
  using F64 = double;
  using F80 = long double;

  using LL  = I64;
  using ULL = U64;
  using LD  = F80;

  // Extended precision types:
  #ifdef __SIZEOF_INT128__
    using I128 = __int128;
    using U128 = unsigned __int128;
  #else
    using I128 = std::int64_t;
    using U128 = std::uint64_t;
  #endif

  // Legacy aliases for backward compatibility:
  #ifdef __FLOAT128__
    using F128 = __float128;
  #else
    using F128 = long double;
  #endif

  // Container type aliases:
  template <class T>
  using VC = std::vector<T>;
  template <class T>
  using VVC = VC<VC<T>>;
  template <class T>
  using VVVC = VC<VVC<T>>;
  template <class T>
  using VVVVC = VC<VVVC<T>>;

  // Specialized container aliases:
  using VI   = VC<I32>;
  using VVI  = VVC<I32>;
  using VVVI = VVVC<I32>;
  using VL   = VC<I64>;
  using VVL  = VVC<I64>;
  using VVVL = VVVC<I64>;
  using VB   = VC<bool>;
  using VS   = VC<std::string>;
  using VU8  = VC<U8>;
  using VU32 = VC<U32>;
  using VU64 = VC<U64>;
  using VF   = VC<F64>;

  // Queue and stack aliases:
  template <class T>
  using Deque = std::deque<T>;
  template <class T>
  using Stack = std::stack<T, std::deque<T>>;
  template <class T>
  using Queue = std::queue<T, std::deque<T>>;

  // Pair and tuple aliases:
  template <class T, class U>
  using P = std::pair<T, U>;
  using PII = std::pair<I32, I32>;
  using PLL = std::pair<I64, I64>;
  using PLD = std::pair<ld, ld>;

  template <class T, class U>
  using VP = VC<P<T, U>>;
  using VPII = VC<PII>;
  using VPLL = VC<PLL>;

  // Priority queue aliases
  template <class T>
  using PQ_max = std::priority_queue<T>;
  template <class T>
  using PQ_min = std::priority_queue<T, VC<T>, std::greater<T>>;

  // Map and set aliases:
  template <class K, class V>
  using UMap = std::unordered_map<K, V>;
  template <class T>
  using USet = std::unordered_set<T>;
  template <class T>
  using MSet = std::multiset<T>;
#endif  // __TYPES__

// Mathematical constants:
constexpr long double PI   = 3.141592653589793238462643383279502884L;
constexpr long double E    = 2.718281828459045235360287471352662498L;
constexpr long double EPS  = 1e-9L;
constexpr int         INF  = 0x3f3f3f3f;
constexpr long long   LINF = 0x3f3f3f3f3f3f3f3fLL;
constexpr int         LIM  = 1000000 + 5;
constexpr int         MOD  = 1000000007;
constexpr int         MOD2 = 998244353;

// Advanced FOR loop system:
#define FOR1(a) for (I64 _ = 0; _ < (a); ++_)
#define FOR2(i, a) for (I64 i = 0; i < (a); ++i)
#define FOR3(i, a, b) for (I64 i = (a); i < (b); ++i)
#define FOR4(i, a, b, c) for (I64 i = (a); i < (b); i += (c))
#define FOR1_R(a) for (I64 i = (a) - 1; i >= 0; --i)
#define FOR2_R(i, a) for (I64 i = (a) - 1; i >= 0; --i)
#define FOR3_R(i, a, b) for (I64 i = (b) - 1; i >= (a); --i)

#define overload4(a, b, c, d, e, ...) e
#define overload3(a, b, c, d, ...) d
#define FOR(...) overload4(__VA_ARGS__, FOR4, FOR3, FOR2, FOR1)(__VA_ARGS__)
#define FOR_R(...) overload3(__VA_ARGS__, FOR3_R, FOR2_R, FOR1_R)(__VA_ARGS__)

using namespace std;
// clang-format on

//===----------------------------------------------------------------------===//
/* Data Types and Function Definitions */

// Function to solve a single test case.
void solve() {
  // Your solution here
}

//===----------------------------------------------------------------------===//
/* Main function */

auto main() -> int {
  // Fast I/O
  ios_base::sync_with_stdio(false);
  cin.tie(nullptr);

  int T = 1;
  cin >> T;
  for ([[maybe_unused]] auto _ : std::views::iota(0, T)) {
    solve();
  }

  return 0;
}

//===----------------------------------------------------------------------===//
