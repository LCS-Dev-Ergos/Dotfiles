# ============================================================================ #
# +++++++++++++++++++++++++++++++++ ALIASES ++++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Convenience aliases and quick problem runners.
# Includes helper for problem letter/numbered variants.
#
# Functions:
#   - _cppgo_problem  Resolve problem target and run it.
#
# ============================================================================ #

# --------------------------- SOME USEFUL ALIASES ---------------------------- #
# Shorter aliases for convenience.
alias cppc='cppconf'
alias cppb='cppbuild'
alias cppr='cpprun'
alias cppg='cppgo'
alias cppi='cppi'
alias cppj='cppjudge'
alias cpps='cppstats'
alias cppcl='cppclean'
alias cppdc='cppdeepclean'
alias cppw='cppwatch'
alias cppn='cppnew'
alias cppdel='cppdelete'
alias cppf='cppforcego'
alias cppct='cppcontest'
alias cppar='cpparchive'
alias cppst='cppstress'
alias cppd='cppdiag'
alias cppin='cppinit'
alias cpph='cpphelp'

# -----------------------------------------------------------------------------
# _cppgo_problem
# -----------------------------------------------------------------------------
# Resolve a problem target (with optional numeric suffix) and run it.
#
# Usage:
#   _cppgo_problem <letter>
# -----------------------------------------------------------------------------
function _cppgo_problem() {
  local problem_id="$1"
  local target_name="problem_${problem_id}"
  local input_file="${target_name}.in"

  # Check if the target file exists, if not try with numeric suffix.
  if [ ! -f "${target_name}.cpp" ] && [ ! -f "${target_name}.cc" ] && [ ! -f "${target_name}.cxx" ]; then
    # Try with numeric suffix (problem_A1, problem_A2, etc.).
    local found_file=""
    for ext in cpp cc cxx; do
      for num in {1..9}; do
        if [ -f "${target_name}${num}.${ext}" ]; then
          target_name="${target_name}${num}"
          input_file="${target_name}.in"
          found_file="${target_name}.${ext}"
          break 2
        fi
      done
    done

    if [ -z "$found_file" ]; then
      echo "${C_RED}Error: No file found for problem '${problem_id}' (tried ${target_name}.* and ${target_name}[1-9].*).${C_RESET}" >&2
      return 1
    fi
  fi

  cppgo "$target_name" "$input_file"
}

# Create aliases for common problem letters
for letter in {A..H}; do
  alias cppgo_${letter}="_cppgo_problem ${letter}"
done

# Create numbered variant aliases (e.g., cppgo_A1, cppgo_A2, etc.)
for letter in {A..H}; do
  for num in {1..9}; do
    alias cppgo_${letter}${num}="cppgo problem_${letter}${num} problem_${letter}${num}.in"
  done
done

# ============================================================================ #
# End of 60-aliases.zsh
