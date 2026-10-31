#!/bin/zsh
# Fails if any of the given binaries was built with code-coverage instrumentation.
# Instrumented binaries write default.profraw files and (in principle) run slower; a shipped build must never have it.
# Used by scripts/build.sh on every build. Usage: scripts/check_no_coverage.sh <binary> ...
bad=0
for bin in "$@"; do
  if otool -l "$bin" 2>/dev/null | grep -q '__llvm_prf'; then
    echo "ERROR: $bin contains code-coverage instrumentation (__llvm_prf sections)." >&2
    bad=1
  fi
done
exit $bad
