#!/bin/bash
#
# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

# Writes the C++ source files and a corresponding BUILD file for which to
# collect code coverage. The sources are a.cc, a.h and t.cc.
function setup_a_cc_lib_and_t_cc_test() {
  cat << EOF > BUILD
cc_library(
    name = "a",
    srcs = ["a.cc"],
    hdrs = ["a.h"],
)

cc_test(
    name = "t",
    srcs = ["t.cc"],
    deps = [":a"],
)
EOF

  cat << EOF > a.h
int a(bool what);
EOF

  cat << EOF > a.cc
#include "a.h"

int a(bool what) {
  if (what) {
    return 1;
  } else {
    return 2;
  }
}
EOF

  cat << EOF > t.cc
#include <stdio.h>
#include "a.h"

int main(void) {
  a(true);
}
EOF
}

# Returns 0 if gcov is not installed or if a version before 7.0 was found.
# Returns 1 otherwise.
function is_gcov_uninstalled_or_wrong_version() {
  local -r gcov_location=$(which gcov)
  if [[ ! -x ${gcov_location:-/usr/bin/gcov} ]]; then
    echo "gcov not installed."
    return 0
  fi

  "$gcov_location" -version | grep "LLVM" && \
      echo "gcov LLVM version not supported." && return 0
  # gcov -v | grep "gcov" outputs a line that looks like this:
  # gcov (Debian 7.3.0-5) 7.3.0
  local gcov_version="$(gcov -v | grep "gcov" | cut -d " " -f 4 | cut -d "." -f 1)"
  [ "$gcov_version" -lt 7 ] \
      && echo "gcov versions before 7.0 is not supported." && return 0
  return 1
}

# Asserts if the given expected coverage result is included in the given output
# file.
#
# - expected_coverage The expected result that must be included in the output.
# - output_file       The location of the coverage output file.
function assert_coverage_result() {
    local expected_coverage="${1}"; shift
    local output_file="${1}"; shift

    # Replace newlines with commas to facilitate the assertion.
    local expected_coverage_no_newlines="$( echo "$expected_coverage" | tr '\n' ',' )"
    local output_file_no_newlines="$( cat "$output_file" | tr '\n' ',' )"

    ( echo $output_file_no_newlines | grep  $expected_coverage_no_newlines ) \
        || fail "Expected coverage result
<$expected_coverage>
was not found in actual coverage report:
<$( cat "$output_file" )>"
}

# Returns the path of the code coverage report that was generated by Bazel by
# looking at the current $TEST_log. The method fails if TEST_log does not
# contain any coverage report for a passed test.
function get_coverage_file_path_from_test_log() {
  local ending_part="$(sed -n -e '/PASSED/,$p' "$TEST_log")"

  local coverage_file_path=$(grep -Eo "/[/a-zA-Z0-9\.\_\-]+\.dat$" <<< "$ending_part")
  [[ -e "$coverage_file_path" ]] || fail "Coverage output file does not exist!"
  echo "$coverage_file_path"
}

function test_cc_test_coverage_lcov() {
  local -r lcov_location=$(which lcov)
  if [[ ! -x "${lcov_location:-/usr/bin/lcov}" ]]; then
    echo "lcov not installed. Skipping test."
    return
  fi

  setup_a_cc_lib_and_t_cc_test

  bazel coverage --test_output=all --build_event_text_file=bep.txt //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"

  local coverage_output_file="$( get_coverage_file_path_from_test_log )"

  # Check the expected coverage for a.cc in the coverage file.
  local expected_result_a_cc="SF:a.cc
FN:3,_Z1ab
FNDA:1,_Z1ab
FNF:1
FNH:1
DA:3,1
DA:4,1
DA:5,1
DA:7,0
LH:3
LF:4
end_of_record"
  assert_coverage_result "$expected_result_a_cc" "$coverage_output_file"
  # t.cc is not included in the coverage report because test targets are not
  # instrumented by default.
  assert_not_contains "SF:t\.cc" "$coverage_output_file"

  # Verify that this is also true for cached coverage actions.
  bazel coverage --test_output=all --build_event_text_file=bep.txt //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"
  expect_log '//:t.*cached'
  # Verify the files are reported correctly in the build event protocol.
  assert_contains 'name: "test.lcov"' bep.txt
  assert_contains 'name: "baseline.lcov"' bep.txt
}

function test_cc_test_coverage_gcov() {
  if is_gcov_uninstalled_or_wrong_version; then
    echo "Skipping test." && return
  fi

  setup_a_cc_lib_and_t_cc_test

  bazel coverage --experimental_cc_coverage --test_output=all \
     --build_event_text_file=bep.txt //:t &>"$TEST_log" \
     || fail "Coverage for //:t failed"

  local coverage_file_path="$( get_coverage_file_path_from_test_log )"

  # Check the expected coverage for a.cc in the coverage file.
  local expected_result_a_cc="SF:a.cc
FN:3,_Z1ab
FNDA:1,_Z1ab
FNF:1
FNH:1
BA:4,2
BRF:1
BRH:1
DA:3,1
DA:4,1
DA:5,1
DA:7,0
LH:3
LF:4
end_of_record"
  assert_coverage_result "$expected_result_a_cc" "$coverage_file_path"
  # t.cc is not included in the coverage report because test targets are not
  # instrumented by default.
  assert_not_contains "SF:t\.cc" "$coverage_file_path"

  # Verify that this is also true for cached coverage actions.
  bazel coverage --experimental_cc_coverage --test_output=all \
      --build_event_text_file=bep.txt //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"
  expect_log '//:t.*cached'
  # Verify the files are reported correctly in the build event protocol.
  assert_contains 'name: "test.lcov"' bep.txt
  assert_contains 'name: "baseline.lcov"' bep.txt
}

function test_cc_test_gcov_multiple_headers() {
  if is_gcov_uninstalled_or_wrong_version; then
    echo "Skipping test." && return
  fi

  ############## Setting up the test sources and BUILD file ##############
  mkdir -p "coverage_srcs/"
  cat << EOF > BUILD
cc_library(
  name = "a",
  srcs = ["coverage_srcs/a.cc"],
  hdrs = ["coverage_srcs/a.h", "coverage_srcs/b.h"]
)

cc_test(
  name = "t",
  srcs = ["coverage_srcs/t.cc"],
  deps = [":a"]
)
EOF
  cat << EOF > "coverage_srcs/a.h"
int a(bool what);
EOF

  cat << EOF > "coverage_srcs/a.cc"
#include "a.h"
#include "b.h"
#include <iostream>

int a(bool what) {
  if (what) {
    std::cout << "Calling b(1)";
    return b(1);
  } else {
    std::cout << "Calling b(-1)";
    return b(-1);
  }
}
EOF

  cat << EOF > "coverage_srcs/b.h"
int b(int what) {
  if (what > 0) {
    return 1;
  } else {
    return 2;
  }
}
EOF

  cat << EOF > "coverage_srcs/t.cc"
#include <stdio.h>
#include "a.h"

int main(void) {
  a(true);
}
EOF

  ############## Running bazel coverage ##############
  bazel coverage --experimental_cc_coverage --test_output=all //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"

  ##### Putting together the expected coverage results #####
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"
  local expected_result_a_cc="SF:coverage_srcs/a.cc
FN:13,_GLOBAL__sub_I_a.cc
FN:5,_Z1ab
FN:13,_Z41__static_initialization_and_destruction_0ii
FNDA:1,_GLOBAL__sub_I_a.cc
FNDA:1,_Z1ab
FNDA:1,_Z41__static_initialization_and_destruction_0ii
FNF:3
FNH:3
BA:6,2
BA:13,2
BRF:2
BRH:2
DA:5,1
DA:6,1
DA:7,1
DA:8,1
DA:10,0
DA:11,0
DA:13,3
LH:5
LF:7
end_of_record"
  local expected_result_b_h="SF:coverage_srcs/b.h
FN:1,_Z1bi
FNDA:1,_Z1bi
FNF:1
FNH:1
BA:2,2
BRF:1
BRH:1
DA:1,1
DA:2,1
DA:3,1
DA:5,0
LH:3
LF:4
end_of_record"
  local expected_result_t_cc="SF:coverage_srcs/t.cc
FN:4,main
FNDA:1,main
FNF:1
FNH:1
DA:4,1
DA:5,1
DA:6,1
LH:3
LF:3
end_of_record"

  ############## Asserting the coverage results ##############
  assert_coverage_result "$expected_result_a_cc" "$coverage_file_path"
  assert_coverage_result "$expected_result_b_h" "$coverage_file_path"
  # coverage_srcs/t.cc is not included in the coverage report because the test
  # targets are not instrumented by default.
  assert_not_contains "SF:coverage_srcs/t\.cc" "$coverage_file_path"
  # iostream should not be in the final coverage report because it is a syslib
  assert_not_contains "iostream" "$coverage_file_path"
}

function test_cc_test_gcov_multiple_headers_instrument_test_target() {
  if is_gcov_uninstalled_or_wrong_version; then
    echo "Skipping test." && return
  fi

  ############## Setting up the test sources and BUILD file ##############
  mkdir -p "coverage_srcs/"
  cat << EOF > BUILD
cc_library(
  name = "a",
  srcs = ["coverage_srcs/a.cc"],
  hdrs = ["coverage_srcs/a.h", "coverage_srcs/b.h"]
)

cc_test(
  name = "t",
  srcs = ["coverage_srcs/t.cc"],
  deps = [":a"]
)
EOF
  cat << EOF > "coverage_srcs/a.h"
int a(bool what);
EOF

  cat << EOF > "coverage_srcs/a.cc"
#include "a.h"
#include "b.h"
#include <iostream>

int a(bool what) {
  if (what) {
    std::cout << "Calling b(1)";
    return b(1);
  } else {
    std::cout << "Calling b(-1)";
    return b(-1);
  }
}
EOF

  cat << EOF > "coverage_srcs/b.h"
int b(int what) {
  if (what > 0) {
    return 1;
  } else {
    return 2;
  }
}
EOF

  cat << EOF > "coverage_srcs/t.cc"
#include <stdio.h>
#include "a.h"

int main(void) {
  a(true);
}
EOF

  ############## Running bazel coverage ##############
  bazel coverage --experimental_cc_coverage --instrument_test_targets \
      --test_output=all //:t &>"$TEST_log" || fail "Coverage for //:t failed"

  ##### Putting together the expected coverage results #####
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"
  local expected_result_a_cc="SF:coverage_srcs/a.cc
FN:13,_GLOBAL__sub_I_a.cc
FN:5,_Z1ab
FN:13,_Z41__static_initialization_and_destruction_0ii
FNDA:1,_GLOBAL__sub_I_a.cc
FNDA:1,_Z1ab
FNDA:1,_Z41__static_initialization_and_destruction_0ii
FNF:3
FNH:3
BA:6,2
BA:13,2
BRF:2
BRH:2
DA:5,1
DA:6,1
DA:7,1
DA:8,1
DA:10,0
DA:11,0
DA:13,3
LH:5
LF:7
end_of_record"
  local expected_result_b_h="SF:coverage_srcs/b.h
FN:1,_Z1bi
FNDA:1,_Z1bi
FNF:1
FNH:1
BA:2,2
BRF:1
BRH:1
DA:1,1
DA:2,1
DA:3,1
DA:5,0
LH:3
LF:4
end_of_record"
  local expected_result_t_cc="SF:coverage_srcs/t.cc
FN:4,main
FNDA:1,main
FNF:1
FNH:1
DA:4,1
DA:5,1
DA:6,1
LH:3
LF:3
end_of_record"

  ############## Asserting the coverage results ##############
  assert_coverage_result "$expected_result_a_cc" "$coverage_file_path"
  assert_coverage_result "$expected_result_b_h" "$coverage_file_path"
  # coverage_srcs/t.cc should be included in the coverage report
  assert_coverage_result "$expected_result_t_cc" "$coverage_file_path"
  # iostream should not be in the final coverage report because it is a syslib
  assert_not_contains "iostream" "$coverage_file_path"
}

function test_cc_test_gcov_same_header_different_libs() {
  if is_gcov_uninstalled_or_wrong_version; then
    echo "Skipping test." && return
  fi

  ############## Setting up the test sources and BUILD file ##############
  mkdir -p "coverage_srcs/"
  cat << EOF > BUILD
cc_library(
  name = "a",
  srcs = ["coverage_srcs/a.cc"],
  hdrs = ["coverage_srcs/a.h", "coverage_srcs/b.h"]
)

cc_library(
  name = "c",
  srcs = ["coverage_srcs/c.cc"],
  hdrs = ["coverage_srcs/c.h", "coverage_srcs/b.h"]
)

cc_test(
  name = "t",
  srcs = ["coverage_srcs/t.cc"],
  deps = [":a", ":c"]
)
EOF
  cat << EOF > "coverage_srcs/a.h"
int a(bool what);
EOF

  cat << EOF > "coverage_srcs/a.cc"
#include "a.h"
#include "b.h"

int a(bool what) {
  if (what) {
    return b_for_a(1);
  } else {
    return b_for_a(-1);
  }
}
EOF

  cat << EOF > "coverage_srcs/b.h"
// Lines 2-8 are covered by calling b_for_a from a.cc.
int b_for_a(int what) { // Line 2: executed once
  if (what > 0) { // Line 3: executed once
    return 1; // Line 4: executed once
  } else {
    return 2; // Line 6: not executed
  }
}

// Lines 11-17 are covered by calling b_for_a from a.cc.
int b_for_c(int what) { // Line 11: executed once
  if (what > 0) { // Line 12: executed once
    return 1; // Line 13: not executed
  } else {
    return 2; // Line 15: executed once
  }
}
EOF

  cat << EOF > "coverage_srcs/c.h"
int c(bool what);
EOF

  cat << EOF > "coverage_srcs/c.cc"
#include "c.h"
#include "b.h"

int c(bool what) {
  if (what) {
    return b_for_c(1);
  } else {
    return b_for_c(-1);
  }
}
EOF

  cat << EOF > "coverage_srcs/t.cc"
#include "a.h"
#include "c.h"

int main(void) {
  a(true);
  c(false);
}
EOF

  ############## Running bazel coverage ##############
  bazel coverage --experimental_cc_coverage --test_output=all //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"

  ##### Putting together the expected coverage results #####
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"
  local expected_result_a_cc="SF:coverage_srcs/a.cc
FN:4,_Z1ab
FNDA:1,_Z1ab
FNF:1
FNH:1
BA:5,2
BRF:1
BRH:1
DA:4,1
DA:5,1
DA:6,1
DA:8,0
LH:3
LF:4
end_of_record"
  local expected_result_b_h="SF:coverage_srcs/b.h
FN:2,_Z7b_for_ai
FN:11,_Z7b_for_ci
FNDA:1,_Z7b_for_ai
FNDA:1,_Z7b_for_ci
FNF:2
FNH:2
BA:3,2
BA:12,2
BRF:2
BRH:2
DA:2,1
DA:3,1
DA:4,1
DA:6,0
DA:11,1
DA:12,1
DA:13,0
DA:15,1
LH:6
LF:8
end_of_record"
  local expected_result_c_cc="SF:coverage_srcs/c.cc
FN:4,_Z1cb
FNDA:1,_Z1cb
FNF:1
FNH:1
BA:5,2
BRF:1
BRH:1
DA:4,1
DA:5,1
DA:6,0
DA:8,1
LH:3
LF:4
end_of_record"

  ############## Asserting the coverage results ##############
  assert_coverage_result "$expected_result_a_cc" "$coverage_file_path"
  assert_coverage_result "$expected_result_b_h" "$coverage_file_path"
  assert_coverage_result "$expected_result_c_cc" "$coverage_file_path"
  # coverage_srcs/t.cc is not included in the coverage report because the test
  # targets are not instrumented by default.
  assert_not_contains "SF:coverage_srcs/t\.cc" "$coverage_file_path"
}

function test_cc_test_gcov_same_header_different_libs_multiple_exec() {
  if is_gcov_uninstalled_or_wrong_version; then
    echo "Skipping test." && return
  fi

  ############## Setting up the test sources and BUILD file ##############
  mkdir -p "coverage_srcs/"
  cat << EOF > BUILD
cc_library(
  name = "a",
  srcs = ["coverage_srcs/a.cc"],
  hdrs = ["coverage_srcs/a.h", "coverage_srcs/b.h"]
)

cc_library(
  name = "c",
  srcs = ["coverage_srcs/c.cc"],
  hdrs = ["coverage_srcs/c.h", "coverage_srcs/b.h"]
)

cc_test(
  name = "t",
  srcs = ["coverage_srcs/t.cc"],
  deps = [":a", ":c"]
)
EOF
  cat << EOF > "coverage_srcs/a.h"
int a(bool what);
int a_redirect();
EOF

  cat << EOF > "coverage_srcs/a.cc"
#include "a.h"
#include "b.h"

int a(bool what) {
  if (what) {
    return b_for_a(1);
  } else {
    return b_for_a(-1);
  }
}

int a_redirect() {
  return b_for_all();
}
EOF

  cat << EOF > "coverage_srcs/b.h"
// Lines 2-8 are covered by calling b_for_a from a.cc.
int b_for_a(int what) { // Line 2: executed once
  if (what > 0) { // Line 3: executed once
    return 1; // Line 4: executed once
  } else {
    return 2; // Line 6: not executed
  }
}

// Lines 11-17 are covered by calling b_for_a from a.cc.
int b_for_c(int what) { // Line 11: executed once
  if (what > 0) { // Line 12: executed once
    return 1; // Line 13: not executed
  } else {
    return 2; // Line 15: executed once
  }
}

int b_for_all() { // Line 21: executed 3 times (2x from a.cc and 1x from c.cc)
  return 10; // Line 21: executed 3 times (2x from a.cc and 1x from c.cc)
}
EOF

  cat << EOF > "coverage_srcs/c.h"
int c(bool what);
int c_redirect();
EOF

  cat << EOF > "coverage_srcs/c.cc"
#include "c.h"
#include "b.h"

int c(bool what) {
  if (what) {
    return b_for_c(1);
  } else {
    return b_for_c(-1);
  }
}

int c_redirect() {
  return b_for_all();
}
EOF

  cat << EOF > "coverage_srcs/t.cc"
#include "a.h"
#include "c.h"

int main(void) {
  a(true);
  c(false);
  a_redirect();
  a_redirect();
  c_redirect();
}
EOF

  ############## Running bazel coverage ##############
  bazel coverage --experimental_cc_coverage --test_output=all //:t \
      &>"$TEST_log" || fail "Coverage for //:t failed"

  ##### Putting together the expected coverage results #####
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"
  local expected_result_a_cc="SF:coverage_srcs/a.cc
FN:12,_Z10a_redirectv
FN:4,_Z1ab
FNDA:2,_Z10a_redirectv
FNDA:1,_Z1ab
FNF:2
FNH:2
BA:5,2
BRF:1
BRH:1
DA:4,1
DA:5,1
DA:6,1
DA:8,0
DA:12,2
DA:13,2
LH:5
LF:6
end_of_record"
  local expected_result_b_h="SF:coverage_srcs/b.h
FN:2,_Z7b_for_ai
FN:11,_Z7b_for_ci
FN:19,_Z9b_for_allv
FNDA:1,_Z7b_for_ai
FNDA:1,_Z7b_for_ci
FNDA:3,_Z9b_for_allv
FNF:3
FNH:3
BA:3,2
BA:12,2
BRF:2
BRH:2
DA:2,1
DA:3,1
DA:4,1
DA:6,0
DA:11,1
DA:12,1
DA:13,0
DA:15,1
DA:19,3
DA:20,3
LH:8
LF:10
end_of_record"
  local expected_result_c_cc="SF:coverage_srcs/c.cc
FN:12,_Z10c_redirectv
FN:4,_Z1cb
FNDA:1,_Z10c_redirectv
FNDA:1,_Z1cb
FNF:2
FNH:2
BA:5,2
BRF:1
BRH:1
DA:4,1
DA:5,1
DA:6,0
DA:8,1
DA:12,1
DA:13,1
LH:5
LF:6
end_of_record"

  ############## Asserting the coverage results ##############
  assert_coverage_result "$expected_result_a_cc" "$coverage_file_path"
  assert_coverage_result "$expected_result_b_h" "$coverage_file_path"
  assert_coverage_result "$expected_result_c_cc" "$coverage_file_path"
  # coverage_srcs/t.cc is not included in the coverage report because the test
  # targets are not instrumented by default.
  assert_not_contains "SF:coverage_srcs/t\.cc" "$coverage_file_path"
}

function test_cc_test_llvm_coverage_doesnt_fail() {
  local -r llvmprofdata=$(which llvm-profdata)
  if [[ ! -x ${llvmprofdata:-/usr/bin/llvm-profdata} ]]; then
    echo "llvm-profdata not installed. Skipping test."
    return
  fi

  local -r clang_tool=$(which clang++)
  if [[ ! -x ${clang_tool:-/usr/bin/clang_tool} ]]; then
    echo "clang++ not installed. Skipping test."
    return
  fi

  setup_a_cc_lib_and_t_cc_test

  # Only test that bazel coverage doesn't crash when invoked for llvm native
  # coverage.
  BAZEL_USE_LLVM_NATIVE_COVERAGE=1 GCOV=$llvmprofdata CC=$clang_tool \
      bazel coverage --test_output=all //:t &>$TEST_log \
      || fail "Coverage for //:t failed"

  # Check to see if the coverage output file was created. Cannot check its
  # contents because it's a binary.
  [ -f "$(get_coverage_file_path_from_test_log)" ] \
      || fail "Coverage output file was not created."
}


function test_failed_coverage() {
  local -r LCOV=$(which lcov)
  if [[ ! -x ${LCOV:-/usr/bin/lcov} ]]; then
    echo "lcov not installed. Skipping test."
    return
  fi

  cat << EOF > BUILD
cc_library(
    name = "a",
    srcs = ["a.cc"],
    hdrs = ["a.h"],
)

cc_test(
    name = "t",
    srcs = ["t.cc"],
    deps = [":a"],
)
EOF

  cat << EOF > a.h
int a();
EOF

  cat << EOF > a.cc
#include "a.h"

int a() {
  return 1;
}
EOF

  cat << EOF > t.cc
#include <stdio.h>
#include "a.h"

int main(void) {
  return a();
}
EOF

  bazel coverage --test_output=all --build_event_text_file=bep.txt //:t \
      &>$TEST_log && fail "Expected test failure" || :

  # Verify that coverage data is still reported.
  assert_contains 'name: "test.lcov"' bep.txt
}

function test_java_test_coverage() {

  cat <<EOF > BUILD
java_test(
    name = "test",
    srcs = glob(["src/test/**/*.java"]),
    test_class = "com.example.TestCollatz",
    deps = [":collatz-lib"],
)

java_library(
    name = "collatz-lib",
    srcs = glob(["src/main/**/*.java"]),
)
EOF

  mkdir -p src/main/com/example
  cat <<EOF > src/main/com/example/Collatz.java
package com.example;

public class Collatz {

  public static int getCollatzFinal(int n) {
    if (n == 1) {
      return 1;
    }
    if (n % 2 == 0) {
      return getCollatzFinal(n / 2);
    } else {
      return getCollatzFinal(n * 3 + 1);
    }
  }

}
EOF

  mkdir -p src/test/com/example
  cat <<EOF > src/test/com/example/TestCollatz.java
package com.example;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public class TestCollatz {

  @Test
  public void testGetCollatzFinal() {
    assertEquals(Collatz.getCollatzFinal(1), 1);
    assertEquals(Collatz.getCollatzFinal(5), 1);
    assertEquals(Collatz.getCollatzFinal(10), 1);
    assertEquals(Collatz.getCollatzFinal(21), 1);
  }

}
EOF

  bazel coverage --test_output=all //:test &>$TEST_log || fail "Coverage for //:test failed"
  cat $TEST_log
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"

  cat <<EOF > result.dat
SF:com/example/Collatz.java
FN:3,com/example/Collatz::<init> ()V
FN:6,com/example/Collatz::getCollatzFinal (I)I
FNDA:0,com/example/Collatz::<init> ()V
FNDA:1,com/example/Collatz::getCollatzFinal (I)I
FNF:2
FNH:1
BA:6,2
BA:9,2
BRF:2
BRH:2
DA:3,0
DA:6,3
DA:7,2
DA:9,4
DA:10,5
DA:12,7
LH:5
LF:6
end_of_record
EOF

  diff result.dat "$coverage_file_path" >> $TEST_log
  if ! cmp result.dat $coverage_file_path; then
    fail "Coverage output file is different with expected"
  fi
}

function test_java_test_coverage_combined_report() {

  cat <<EOF > BUILD
java_test(
    name = "test",
    srcs = glob(["src/test/**/*.java"]),
    test_class = "com.example.TestCollatz",
    deps = [":collatz-lib"],
)

java_library(
    name = "collatz-lib",
    srcs = glob(["src/main/**/*.java"]),
)
EOF

  mkdir -p src/main/com/example
  cat <<EOF > src/main/com/example/Collatz.java
package com.example;

public class Collatz {

  public static int getCollatzFinal(int n) {
    if (n == 1) {
      return 1;
    }
    if (n % 2 == 0) {
      return getCollatzFinal(n / 2);
    } else {
      return getCollatzFinal(n * 3 + 1);
    }
  }

}
EOF

  mkdir -p src/test/com/example
  cat <<EOF > src/test/com/example/TestCollatz.java
package com.example;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public class TestCollatz {

  @Test
  public void testGetCollatzFinal() {
    assertEquals(Collatz.getCollatzFinal(1), 1);
    assertEquals(Collatz.getCollatzFinal(5), 1);
    assertEquals(Collatz.getCollatzFinal(10), 1);
    assertEquals(Collatz.getCollatzFinal(21), 1);
  }

}
EOF

  bazel coverage --test_output=all //:test --coverage_report_generator=@bazel_tools//tools/test/CoverageOutputGenerator/java/com/google/devtools/coverageoutputgenerator:Main --combined_report=lcov &>$TEST_log \
   || echo "Coverage for //:test failed"

  cat <<EOF > result.dat
SF:com/example/Collatz.java
FN:3,com/example/Collatz::<init> ()V
FN:6,com/example/Collatz::getCollatzFinal (I)I
FNDA:0,com/example/Collatz::<init> ()V
FNDA:1,com/example/Collatz::getCollatzFinal (I)I
FNF:2
FNH:1
BA:6,2
BA:9,2
BRF:2
BRH:2
DA:3,0
DA:6,3
DA:7,2
DA:9,4
DA:10,5
DA:12,7
LH:5
LF:6
end_of_record
EOF

  if ! cmp result.dat ./bazel-out/_coverage/_coverage_report.dat; then
    diff result.dat bazel-out/_coverage/_coverage_report.dat >> $TEST_log
    fail "Coverage output file is different with expected"
  fi
}

function test_java_test_java_import_coverage() {

  cat <<EOF > BUILD
java_test(
    name = "test",
    srcs = glob(["src/test/**/*.java"]),
    test_class = "com.example.TestCollatz",
    deps = [":collatz-import"],
)

java_import(
    name = "collatz-import",
    jars = [":libcollatz-lib.jar"],
)

java_library(
    name = "collatz-lib",
    srcs = glob(["src/main/**/*.java"]),
)
EOF

  mkdir -p src/main/com/example
  cat <<EOF > src/main/com/example/Collatz.java
package com.example;

public class Collatz {

  public static int getCollatzFinal(int n) {
    if (n == 1) {
      return 1;
    }
    if (n % 2 == 0) {
      return getCollatzFinal(n / 2);
    } else {
      return getCollatzFinal(n * 3 + 1);
    }
  }

}
EOF

  mkdir -p src/test/com/example
  cat <<EOF > src/test/com/example/TestCollatz.java
package com.example;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public class TestCollatz {

  @Test
  public void testGetCollatzFinal() {
    assertEquals(Collatz.getCollatzFinal(1), 1);
    assertEquals(Collatz.getCollatzFinal(5), 1);
    assertEquals(Collatz.getCollatzFinal(10), 1);
    assertEquals(Collatz.getCollatzFinal(21), 1);
  }

}
EOF

  bazel coverage --test_output=all --experimental_java_coverage //:test &>$TEST_log || fail "Coverage for //:test failed"
  local coverage_file_path="$( get_coverage_file_path_from_test_log )"

  cat <<EOF > result.dat
SF:src/main/com/example/Collatz.java
FN:3,com/example/Collatz::<init> ()V
FN:6,com/example/Collatz::getCollatzFinal (I)I
FNDA:0,com/example/Collatz::<init> ()V
FNDA:1,com/example/Collatz::getCollatzFinal (I)I
FNF:2
FNH:1
BA:6,2
BA:9,2
BRF:2
BRH:2
DA:3,0
DA:6,3
DA:7,2
DA:9,4
DA:10,5
DA:12,7
LH:5
LF:6
end_of_record
EOF
  diff result.dat "$coverage_file_path" >> $TEST_log
  cmp result.dat "$coverage_file_path" || fail "Coverage output file is different than the expected file"
}

function test_sh_test_coverage() {
  cat <<EOF > BUILD
sh_test(
    name = "orange-sh",
    srcs = ["orange-test.sh"],
    data = ["//java/com/google/orange:orange-bin"]
)
EOF
  cat <<EOF > orange-test.sh
#!/bin/bash

java/com/google/orange/orange-bin
EOF
  chmod +x orange-test.sh

  mkdir -p java/com/google/orange

  cat <<EOF > java/com/google/orange/BUILD
package(default_visibility = ["//visibility:public"])

java_binary(
    name = "orange-bin",
    srcs = ["orangeBin.java"],
    main_class = "com.google.orange.orangeBin",
    deps = [":orange-lib"],
)

java_library(
    name = "orange-lib",
    srcs = ["orangeLib.java"],
)
EOF

  cat <<EOF > java/com/google/orange/orangeLib.java
package com.google.orange;

public class orangeLib {

  public void print() {
    System.out.println("orange prints a message!");
  }
}
EOF

  cat <<EOF > java/com/google/orange/orangeBin.java
package com.google.orange;

public class orangeBin {
  public static void main(String[] args) {
    orangeLib orange = new orangeLib();
    orange.print();
  }
}
EOF

  bazel coverage --test_output=all //:orange-sh &>$TEST_log || fail "Coverage for //:orange-sh failed"

  local coverage_file_path="$( get_coverage_file_path_from_test_log )"

  cat <<EOF > result.dat
SF:com/google/orange/orangeBin.java
FN:3,com/google/orange/orangeBin::<init> ()V
FN:5,com/google/orange/orangeBin::main ([Ljava/lang/String;)V
FNDA:0,com/google/orange/orangeBin::<init> ()V
FNDA:1,com/google/orange/orangeBin::main ([Ljava/lang/String;)V
FNF:2
FNH:1
DA:3,0
DA:5,4
DA:6,2
DA:7,1
LH:3
LF:4
end_of_record
SF:com/google/orange/orangeLib.java
FN:3,com/google/orange/orangeLib::<init> ()V
FN:6,com/google/orange/orangeLib::print ()V
FNDA:1,com/google/orange/orangeLib::<init> ()V
FNDA:1,com/google/orange/orangeLib::print ()V
FNF:2
FNH:2
DA:3,3
DA:6,3
DA:7,1
LH:3
LF:3
end_of_record
EOF
  diff result.dat "$coverage_file_path" >> $TEST_log
  cmp result.dat "$coverage_file_path" || fail "Coverage output file is different than the expected file"
}

run_suite "test tests"
