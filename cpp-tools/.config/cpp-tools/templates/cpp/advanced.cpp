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
// Compiler optimizations and target-specific features:
#if defined(__GNUC__) && !defined(__clang__)
  #pragma GCC optimize("Ofast,unroll-loops,fast-math,O3,inline-functions")
  #pragma GCC diagnostic push
  #pragma GCC diagnostic ignored "-Wunused-result"
  // Architecture-specific optimizations:
  #ifdef __x86_64__
    #pragma GCC target("avx2,bmi,bmi2,popcnt,lzcnt,sse4.2,fma")
  #endif
  #ifdef __aarch64__
    #pragma GCC target("+simd,+crypto,+fp16")
  #endif
#endif

#ifdef __clang__
  #pragma clang optimize on
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wunused-result"
#endif

// Conditional header inclusion based on environment:
#ifdef USE_CLANG_SANITIZE
  #include "PCH.h"
#else
  #include <bits/stdc++.h>
  // Policy-Based Data Structures:
  #include <ext/pb_ds/assoc_container.hpp>
  #include <ext/pb_ds/tree_policy.hpp>
#endif

// Debug utilities:
#ifdef LOCAL
  #include "../Algorithms/debug.h"
#else
  #define debug(...) 42
  #define debug_if(...) 42
  #define debug_tree(...) 42
  #define debug_tree_verbose(...) 42
  #define debug_line() 42
  #define my_assert(...) 42
  #define COUNT_CALLS(...) 42
#endif

//===----------------------------------------------------------------------===//
/* Advanced Type System and Aliases */

#ifndef __TYPES__
#define __TYPES__

  // Fundamental type aliases with explicit sizes:
  using I8   = std::int8_t;
  using I16  = std::int16_t;
  using I32  = std::int32_t;
  using I64  = std::int64_t;
  using U8   = std::uint8_t;
  using U16  = std::uint16_t;
  using U32  = std::uint32_t;
  using U64  = std::uint64_t;
  using F32  = float;
  using F64  = double;
  using F80  = long double;

  // Extended precision types (when available):
  #ifdef __SIZEOF_INT128__
    using I128 = __int128;
    using U128 = unsigned __int128;
  #else
    using I128 = std::int64_t;
    using U128 = std::uint64_t;
  #endif

  #ifdef __FLOAT128__
    using F128 = __float128;
  #else
    using F128 = long double;
  #endif

  // Legacy aliases for backward compatibility:
  using ll  = I64;
  using ull = U64;
  using ld  = F80;

  // Container type aliases with template parameters:
  template <class T>
  using VC = std::vector<T>;
  template <class T>
  using VVC = VC<VC<T>>;
  template <class T>
  using VVVC = VC<VVC<T>>;
  template <class T>
  using VVVVC = VC<VVVC<T>>;

  // Specialized container aliases:
  using VI = VC<I64>;
  using VVI = VVC<I64>;
  using VVVI = VVVC<I64>;
  using VB = VC<bool>;
  using VS = VC<std::string>;
  using VU8 = VC<U8>;
  using VU32 = VC<U32>;
  using VU64 = VC<U64>;

  // Pair and tuple aliases:
  using PII = std::pair<I32, I32>;
  using PLL = std::pair<I64, I64>;
  using PLD = std::pair<ld, ld>;
  template <class T, class U>
  using P = std::pair<T, U>;

  using VPII = VC<PII>;
  using VPLL = VC<PLL>;
  template <class T, class U>
  using VP = VC<P<T, U>>;

  // Priority queue aliases:
  template <class T>
  using PQ_max = std::priority_queue<T>;
  template <class T>
  using PQ_min = std::priority_queue<T, VC<T>, std::greater<T>>;

  // Advanced container aliases:
  template <class K, class V>
  using UMap = std::unordered_map<K, V>;
  template <class T>
  using USet = std::unordered_set<T>;
  template <class T>
  using MSet = std::multiset<T>;

#endif // __TYPES__

// Policy-based data structures:
using namespace __gnu_pbds;
template <typename T>
using ordered_set = tree<T, null_type, std::less<T>, rb_tree_tag, tree_order_statistics_node_update>;
template <typename T>
using ordered_multiset = tree<T, null_type, std::less_equal<T>, rb_tree_tag, tree_order_statistics_node_update>;

//===----------------------------------------------------------------------===//
/* Mathematical Constants and Infinity Values */

// High-precision mathematical constants:
constexpr F80 PI   = 3.1415926535897932384626433832795028841971693993751L;
constexpr F80 E    = 2.7182818284590452353602874713526624977572470937000L;
constexpr F80 PHI  = 1.6180339887498948482045868343656381177203091798058L;
constexpr F80 LN2  = 0.6931471805599453094172321214581765680755001343602L;
constexpr F80 EPS  = 1e-9L;
constexpr F80 DEPS = 1e-12L;

// Robust infinity system:
template <class T>
constexpr T infinity = std::numeric_limits<T>::max() / 4;

template <>
constexpr I32 infinity<I32> = 1'010'000'000;
template <>
constexpr I64 infinity<I64> = 2'020'000'000'000'000'000LL;
template <>
constexpr U32 infinity<U32> = 2'020'000'000U;
template <>
constexpr U64 infinity<U64> = 4'040'000'000'000'000'000ULL;
template <>
constexpr F64 infinity<F64> = 1e18;
template <>
constexpr F80 infinity<F80> = 1e18L;

#ifdef __SIZEOF_INT128__
template <>
constexpr I128 infinity<I128> = I128(infinity<I64>) * 2'000'000'000'000'000'000LL;
#endif

constexpr I32 INF32 = infinity<I32>;
constexpr I64 INF64 = infinity<I64>;
constexpr I64 LINF  = INF64; // Legacy alias

// Modular arithmetic constants:
constexpr I64 MOD  = 1000000007;
constexpr I64 MOD2 = 998244353;
constexpr I64 MOD3 = 1000000009;

//===----------------------------------------------------------------------===//
/* Advanced Macro System */

// Multi-dimensional vector creation macros:
#define make_vec(type, name, ...) VC<type> name(__VA_ARGS__)
#define vv(type, name, h, ...) \
  VC<VC<type>> name(h, VC<type>(__VA_ARGS__))
#define vvv(type, name, h, w, ...) \
  VC<VC<VC<type>>> name(h, VC<VC<type>>(w, VC<type>(__VA_ARGS__)))
#define vvvv(type, name, a, b, c, ...) \
  VC<VC<VC<VC<type>>>> name(a, VC<VC<VC<type>>>(b, VC<VC<type>>(c, VC<type>(__VA_ARGS__))))

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

// Range-based iteration:
#define REP(i, n) for (I64 i : std::views::iota(0LL, (I64)(n)))
#define RREP(i, n) for (I64 i : std::views::iota(0LL, (I64)(n)) | std::views::reverse)
#define ALL(x) std::ranges::begin(x), std::ranges::end(x)
#define RALL(x) std::ranges::rbegin(x), std::ranges::rend(x)

// Advanced container operations:
#define UNIQUE(x) (std::ranges::sort(x), x.erase(std::ranges::unique(x).begin(), x.end()), x.shrink_to_fit())
#define LB(c, x) (I64)std::distance((c).begin(), std::ranges::lower_bound(c, x))
#define UB(c, x) (I64)std::distance((c).begin(), std::ranges::upper_bound(c, x))
#define SUM(x) std::accumulate(all(x), 0LL)
#define MIN(x) *std::ranges::min_element(x)
#define MAX(x) *std::ranges::max_element(x)

// Container utility macros:
#define all(x) (x).begin(), (x).end()
#define rall(x) (x).rbegin(), (x).rend()
#define sz(x) (I64)(x).size()
#define len(x) sz(x)
#define pb push_back
#define eb emplace_back
#define mp make_pair
#define mt make_tuple
#define fi first
#define se second
#define elif else if

//===----------------------------------------------------------------------===//
/* Optimized I/O System */

namespace fast_io {
  static constexpr U32 BUFFER_SIZE = 1 << 17; // 128KB buffer
  alignas(64) char input_buffer[BUFFER_SIZE];
  alignas(64) char output_buffer[BUFFER_SIZE];
  alignas(64) char number_buffer[128];

  // Precomputed number strings for fast output:
  struct NumberLookup {
    char digits[10000][4];
    constexpr NumberLookup() : digits{} {
      for (I32 i = 0; i < 10000; ++i) {
        digits[i][3] = '0' + (i % 10);
        digits[i][2] = '0' + ((i / 10) % 10);
        digits[i][1] = '0' + ((i / 100) % 10);
        digits[i][0] = '0' + (i / 1000);
      }
    }
  };
  constexpr NumberLookup number_lookup;

  U32 input_pos = 0, input_end = 0, output_pos = 0;

  [[gnu::always_inline]] inline void load_input() {
    std::memmove(input_buffer, input_buffer + input_pos, input_end - input_pos);
    input_end = input_end - input_pos +
                std::fread(input_buffer + input_end - input_pos, 1,
                          BUFFER_SIZE - input_end + input_pos, stdin);
    input_pos = 0;
    if (input_end < BUFFER_SIZE) input_buffer[input_end++] = '\n';
  }

  [[gnu::always_inline]] inline void flush_output() {
    std::fwrite(output_buffer, 1, output_pos, stdout);
    output_pos = 0;
  }

  // Fast character reading:
  [[gnu::always_inline]] inline void read_char(char& c) {
    do {
      if (input_pos >= input_end) load_input();
      c = input_buffer[input_pos++];
    } while (std::isspace(c));
  }

  // Optimized integer reading with SIMD potential:
  template <typename T>
  [[gnu::always_inline]] inline void read_integer(T& x) {
    if (input_pos + 64 >= input_end) load_input();

    char c;
    do { c = input_buffer[input_pos++]; } while (c < '-');

    bool negative = false;
    if constexpr (std::is_signed_v<T>) {
      if (c == '-') {
        negative = true;
        c = input_buffer[input_pos++];
      }
    }

    x = 0;
    while (c >= '0') {
      x = x * 10 + (c - '0');
      c = input_buffer[input_pos++];
    }

    if constexpr (std::is_signed_v<T>) {
      if (negative) x = -x;
    }
  }

  // Fast string reading:
  [[gnu::always_inline]] inline void read_string(std::string& s) {
    s.clear();
    char c;
    do {
      if (input_pos >= input_end) load_input();
      c = input_buffer[input_pos++];
    } while (std::isspace(c));

    do {
      s.push_back(c);
      if (input_pos >= input_end) load_input();
      c = input_buffer[input_pos++];
    } while (!std::isspace(c));
  }

  // Optimized integer writing:
  template <typename T>
  [[gnu::always_inline]] inline void write_integer(T x) {
    if (output_pos + 64 >= BUFFER_SIZE) flush_output();

    if (x < 0) {
      output_buffer[output_pos++] = '-';
      x = -x;
    }

    I32 digits = 0;
    T temp = x;
    do {
      number_buffer[digits++] = '0' + (temp % 10);
      temp /= 10;
    } while (temp > 0);

    // Reverse and copy:
    for (I32 i = digits - 1; i >= 0; --i) {
      output_buffer[output_pos++] = number_buffer[i];
    }
  }

  [[gnu::always_inline]] inline void write_char(char c) {
    if (output_pos >= BUFFER_SIZE) flush_output();
    output_buffer[output_pos++] = c;
  }

  [[gnu::always_inline]] inline void write_string(const std::string& s) {
    for (char c : s) write_char(c);
  }

  // Template-based readers:
  void read(I32& x) { read_integer(x); }
  void read(I64& x) { read_integer(x); }
  void read(U32& x) { read_integer(x); }
  void read(U64& x) { read_integer(x); }
  void read(char& x) { read_char(x); }
  void read(std::string& x) { read_string(x); }

  template <class T, class U>
  void read(std::pair<T, U>& p) { read(p.first); read(p.second); }

  template <class T>
  void read(VC<T>& v) { for (auto& x : v) read(x); }

  // Variadic read:
  template <class Head, class... Tail>
  void read(Head& head, Tail&... tail) {
    read(head);
    if constexpr (sizeof...(tail) > 0) read(tail...);
  }

  // Template-based writers:
  void write(I32 x) { write_integer(x); }
  void write(I64 x) { write_integer(x); }
  void write(U32 x) { write_integer(x); }
  void write(U64 x) { write_integer(x); }
  void write(char x) { write_char(x); }
  void write(const std::string& x) { write_string(x); }
  void write(const char* x) { write_string(std::string(x)); }

  template <class T, class U>
  void write(const std::pair<T, U>& p) {
    write(p.first); write(' '); write(p.second);
  }

  template <class T>
  void write(const VC<T>& v) {
    for (I64 i = 0; i < sz(v); ++i) {
      if (i) write(' ');
      write(v[i]);
    }
  }

  // Variadic write:
  template <class Head, class... Tail>
  void write(const Head& head, const Tail&... tail) {
    write(head);
    if constexpr (sizeof...(tail) > 0) {
      write(' ');
      write(tail...);
    }
  }

  void writeln() { write_char('\n'); }

  template <class... Args>
  void writeln(const Args&... args) {
    if constexpr (sizeof...(args) > 0) write(args...);
    write_char('\n');
  }

  // Destructor for automatic flushing:
  struct IOFlusher {
    ~IOFlusher() { flush_output(); }
  } io_flusher;
}

// Input/Output macros:
#define IN(...) fast_io::read(__VA_ARGS__)
#define OUT(...) fast_io::writeln(__VA_ARGS__)
#define FLUSH() fast_io::flush_output()

// Convenient input macros:
#define INT(...) I32 __VA_ARGS__; IN(__VA_ARGS__)
#define LL(...) I64 __VA_ARGS__; IN(__VA_ARGS__)
#define ULL(...) U64 __VA_ARGS__; IN(__VA_ARGS__)
#define STR(...) std::string __VA_ARGS__; IN(__VA_ARGS__)
#define CHR(...) char __VA_ARGS__; IN(__VA_ARGS__)
#define DBL(...) F64 __VA_ARGS__; IN(__VA_ARGS__)

#define VEC(type, name, size) VC<type> name(size); IN(name)
#define VV(type, name, h, w) VVC<type> name(h, VC<type>(w)); IN(name)

// Answer macros:
void YES(bool condition = true) { OUT(condition ? "YES" : "NO"); }
void NO(bool condition = true) { YES(!condition); }
void Yes(bool condition = true) { OUT(condition ? "Yes" : "No"); }
void No(bool condition = true) { Yes(!condition); }

//===----------------------------------------------------------------------===//
/* Advanced Bitwise Operations */

// Enhanced bit manipulation with SIMD hints:
template <typename T>
[[gnu::always_inline]] constexpr I32 popcount(T x) {
  if constexpr (sizeof(T) <= 4) return __builtin_popcount(x);
  else return __builtin_popcountll(x);
}

template <typename T>
[[gnu::always_inline]] constexpr I32 leading_zeros(T x) {
  if (x == 0) return sizeof(T) * 8;
  if constexpr (sizeof(T) <= 4) return __builtin_clz(x);
  else return __builtin_clzll(x);
}

template <typename T>
[[gnu::always_inline]] constexpr I32 trailing_zeros(T x) {
  if (x == 0) return sizeof(T) * 8;
  if constexpr (sizeof(T) <= 4) return __builtin_ctz(x);
  else return __builtin_ctzll(x);
}

template <typename T>
[[gnu::always_inline]] constexpr I32 bit_width(T x) {
  return sizeof(T) * 8 - leading_zeros(x);
}

template <typename T>
[[gnu::always_inline]] constexpr T bit_floor(T x) {
  if (x == 0) return 0;
  return T(1) << (bit_width(x) - 1);
}

template <typename T>
[[gnu::always_inline]] constexpr T bit_ceil(T x) {
  if (x <= 1) return 1;
  return T(1) << bit_width(x - 1);
}

// Legacy aliases:
template <typename T> constexpr I32 popcnt(T x) { return popcount(x); }
template <typename T> constexpr I32 topbit(T x) { return bit_width(x) - 1; }
template <typename T> constexpr I32 lowbit(T x) { return trailing_zeros(x); }

// Bit iteration utilities:
template <typename T>
constexpr T kth_bit(I32 k) { return T(1) << k; }

template <typename T>
constexpr bool has_kth_bit(T x, I32 k) { return (x >> k) & 1; }

// Bit iteration ranges:
template <typename T>
struct bit_range {
  T mask;
  struct iterator {
    T current;
    iterator(T mask) : current(mask) {}
    I32 operator*() const { return trailing_zeros(current); }
    iterator& operator++() { current &= current - 1; return *this; }
    bool operator!=(const iterator&) const { return current != 0; }
  };
  bit_range(T mask) : mask(mask) {}
  iterator begin() const { return iterator(mask); }
  iterator end() const { return iterator(0); }
};

template <typename T>
struct subset_range {
  T mask;
  struct iterator {
    T subset, original;
    bool finished;
    iterator(T mask) : subset(mask), original(mask), finished(false) {}
    T operator*() const { return original ^ subset; }
    iterator& operator++() {
      if (subset == 0) finished = true;
      else subset = (subset - 1) & original;
      return *this;
    }
    bool operator!=(const iterator&) const { return !finished; }
  };
  subset_range(T mask) : mask(mask) {}
  iterator begin() const { return iterator(mask); }
  iterator end() const { return iterator(0); }
};

//===----------------------------------------------------------------------===//
/* Mathematical Utilities */

// Generic mathematical functions:
template <typename T>
[[gnu::always_inline]] constexpr T gcd(T a, T b) {
  if constexpr (std::is_integral_v<T>) {
    return b ? gcd(b, a % b) : a;
  } else {
    return std::gcd(a, b);
  }
}

template <typename T>
[[gnu::always_inline]] constexpr T lcm(T a, T b) {
  return a / gcd(a, b) * b;
}

// Advanced division operations:
template <typename T>
[[gnu::always_inline]] constexpr T div_floor(T a, T b) {
  return a / b - (a % b != 0 && (a ^ b) < 0);
}

template <typename T>
[[gnu::always_inline]] constexpr T div_ceil(T a, T b) {
  return div_floor(a + b - 1, b);
}

template <typename T>
[[gnu::always_inline]] constexpr T mod_floor(T a, T b) {
  return a - b * div_floor(a, b);
}

template <typename T>
[[gnu::always_inline]] constexpr std::pair<T, T> divmod(T a, T b) {
  T q = div_floor(a, b);
  return {q, a - q * b};
}

// Fast modular exponentiation:
template <typename T>
[[gnu::always_inline]] constexpr T power(T base, T exp, T mod = 0) {
  T result = 1;
  if (mod) base %= mod;
  while (exp > 0) {
    if (exp & 1) {
      result = mod ? (result * base) % mod : result * base;
    }
    base = mod ? (base * base) % mod : base * base;
    exp >>= 1;
  }
  return result;
}

// Min/Max update functions:
template <class T, class S>
[[gnu::always_inline]] inline bool chmax(T& a, const S& b) {
  return a < b ? (a = b, true) : false;
}

template <class T, class S>
[[gnu::always_inline]] inline bool chmin(T& a, const S& b) {
  return a > b ? (a = b, true) : false;
}

// Variadic min/max:
template <typename T>
constexpr const T& min(const T& a, const T& b) { return (b < a) ? b : a; }

template <typename T>
constexpr const T& max(const T& a, const T& b) { return (a < b) ? b : a; }

template <typename T, typename... Args>
constexpr const T& min(const T& a, const T& b, const Args&... args) {
  return min(a, min(b, args...));
}

template <typename T, typename... Args>
constexpr const T& max(const T& a, const T& b, const Args&... args) {
  return max(a, max(b, args...));
}

//===----------------------------------------------------------------------===//
/* Container Utilities and Algorithms */

// Enhanced binary search:
template <typename F>
I64 binary_search(F&& predicate, I64 left, I64 right) {
  while (std::abs(left - right) > 1) {
    I64 mid = left + (right - left) / 2;  // Avoid overflow
    (predicate(mid) ? left : right) = mid;
  }
  return left;
}

template <typename F>
F64 binary_search_real(F&& predicate, F64 left, F64 right, I32 iterations = 100) {
  FOR(iterations) {
    F64 mid = left + (right - left) / 2;
    (predicate(mid) ? left : right) = mid;
  }
  return left + (right - left) / 2;
}

// Container manipulation utilities:
template <typename T>
VC<I32> argsort(const VC<T>& v, bool reverse = false) {
  VC<I32> indices(sz(v));
  std::iota(all(indices), 0);
  if (reverse) {
    std::ranges::sort(indices, [&](I32 i, I32 j) {
      return v[i] == v[j] ? i < j : v[i] > v[j];
    });
  } else {
    std::ranges::sort(indices, [&](I32 i, I32 j) {
      return v[i] == v[j] ? i < j : v[i] < v[j];
    });
  }
  return indices;
}

template <typename T>
VC<T> rearrange(const VC<T>& v, const VC<I32>& indices) {
  VC<T> result(sz(indices));
  FOR(i, sz(indices)) result[i] = v[indices[i]];
  return result;
}

template <typename T>
VC<T> cumsum(const VC<T>& v, bool include_zero = true) {
  VC<T> result(sz(v) + (include_zero ? 1 : 0));
  if (include_zero) {
    FOR(i, sz(v)) result[i + 1] = result[i] + v[i];
  } else {
    result[0] = v[0];
    FOR(i, 1, sz(v)) result[i] = result[i - 1] + v[i];
  }
  return result;
}

// POP utilities for different containers:
template <typename T>
T POP(std::deque<T>& container) {
  T element = container.front();
  container.pop_front();
  return element;
}

template <typename T>
T POP(PQ_min<T>& container) {
  T element = container.top();
  container.pop();
  return element;
}

template <typename T>
T POP(PQ_max<T>& container) {
  T element = container.top();
  container.pop();
  return element;
}

template <typename T>
T POP(VC<T>& container) {
  T element = container.back();
  container.pop_back();
  return element;
}

// String utilities:
VC<I32> string_to_ints(const std::string& s, char base_char = 'a') {
  VC<I32> result(sz(s));
  FOR(i, sz(s)) {
    result[i] = s[i] == '?' ? -1 : s[i] - base_char;
  }
  return result;
}
// clang-format on

//===----------------------------------------------------------------------===//
/* Advanced Modular Arithmetic */

template <I64 MOD>
struct ModInt {
  U64 value;

  static constexpr I64  mod() { return MOD; }
  static constexpr bool is_prime = true;

  constexpr ModInt() : value(0) {}
  constexpr ModInt(I64 x) : value(x >= 0 ? x % MOD : (x % MOD + MOD) % MOD) {}

  constexpr ModInt& operator+=(const ModInt& other) {
    if ((value += other.value) >= MOD)
      value -= MOD;
    return *this;
  }

  constexpr ModInt& operator-=(const ModInt& other) {
    if ((value += MOD - other.value) >= MOD)
      value -= MOD;
    return *this;
  }

  constexpr ModInt& operator*=(const ModInt& other) {
    value = (U64)value * other.value % MOD;
    return *this;
  }

  constexpr ModInt& operator/=(const ModInt& other) { return *this *= other.inverse(); }

  constexpr ModInt operator+(const ModInt& other) const { return ModInt(*this) += other; }
  constexpr ModInt operator-(const ModInt& other) const { return ModInt(*this) -= other; }
  constexpr ModInt operator*(const ModInt& other) const { return ModInt(*this) *= other; }
  constexpr ModInt operator/(const ModInt& other) const { return ModInt(*this) /= other; }
  constexpr ModInt operator-() const { return ModInt(value ? MOD - value : 0); }

  constexpr bool operator==(const ModInt& other) const { return value == other.value; }
  constexpr bool operator!=(const ModInt& other) const { return value != other.value; }

  constexpr ModInt pow(I64 exp) const {
    ModInt result(1), base(*this);
    while (exp > 0) {
      if (exp & 1)
        result *= base;
      base *= base;
      exp >>= 1;
    }
    return result;
  }

  constexpr ModInt inverse() const {
    if constexpr (is_prime) {
      return pow(MOD - 2);
    } else {
      // Extended Euclidean algorithm
      I64 a = value, b = MOD, u = 1, v = 0;
      while (b > 0) {
        I64 t = a / b;
        std::swap(a -= t * b, b);
        std::swap(u -= t * v, v);
      }
      return ModInt(u);
    }
  }

  explicit             operator I64() const { return value; }
  friend std::ostream& operator<<(std::ostream& os, const ModInt& x) { return os << x.value; }
  friend std::istream& operator>>(std::istream& is, ModInt& x) {
    I64 val;
    is >> val;
    x = ModInt(val);
    return is;
  }
};

using mint  = ModInt<MOD>;
using mint2 = ModInt<MOD2>;

//===----------------------------------------------------------------------===//
/* Fast I/O Setup */

using namespace std;

// Fast I/O setup:
struct FastIOSetup {
  FastIOSetup() {
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);
    std::cout.tie(nullptr);
    std::cout << std::fixed << std::setprecision(10);
  }
} fast_io_setup;

//===----------------------------------------------------------------------===//
/* Main Solver Function */

void solve() {
  // Otimized solution here
}

//===----------------------------------------------------------------------===//
/* Main Function */

auto main() -> int {
#ifdef LOCAL
  Timer timer;
  init_debug_log();
#endif

  INT(T);
  FOR(T) solve();

  return 0;
}

//===----------------------------------------------------------------------===//
