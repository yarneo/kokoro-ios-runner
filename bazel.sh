#!/bin/bash
#
# Copyright 2017-present The Kokoro iOS Runner Authors. All Rights Reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Build script for kokoro.
#
# This script will clean, build, and run tests against each installation of Xcode available on the
# machine using bazel.
#
# Ordered arguments:
#   1. action:  bazel ACTION. E.g. "build" or "test".
#   2. target:  Bazel build target. E.g. "//path/to/target:Target"
#
# Named arguments:
#   -m|--min-xcode-version <version>: Every Xcode version equal to or greater than this value will
#                                     build and run tests. E.g. "8.2.1" will run 8.2.1, 8.3.3, 9,
#                                     etc...
#   -v|--verbose:                     Generates verbose output on local runs.
#                                     Does not affect kokoro runs.
#
# Any unrecognized arguments will be passed along to the bazel invocation.
#
# Example usage:
#   bazel.sh build //:CatalogByConvention --min-xcode-version 8.2
#   bazel.sh test //:CatalogByConventionTests -v

# Fail on any error.
set -e

script_version="v4.2.0"
echo "$(basename $0) version $script_version"

version_as_number() {
  padded_version="${1%.}" # Strip any trailing dots
  # Pad with .0 until we get a M.m.p version string.
  while [ $(grep -o "\." <<< "$padded_version" | wc -l) -lt "2" ]; do
    padded_version=${padded_version}.0
  done
  echo "${padded_version//.}"
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  -m|--min-xcode-version)
    MIN_XCODE_VERSION="$(version_as_number $2)"
    shift
    shift
    ;;
  -v|--verbose)
    VERBOSE_OUTPUT="1"
    shift
    ;;
  *)
    POSITIONAL+=("$1")
    shift
    ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [ -n "$KOKORO_BUILD_NUMBER" ]; then
  # Move into our cloned repo
  cd github/repo

  # Always enable verbose output on kokoro runs.
  VERBOSE_OUTPUT=1
fi

if [ -n "$VERBOSE_OUTPUT" ]; then
  verbosity_flags="-s"

  # Display commands to stderr.
  set -x
fi

ACTION="$1"
TARGET="$2"

invoke_bazel() {
  xcode_version="$1"
  sdk_version="$2"
  extra_args=""
  if [ "$ACTION" == "build" ]; then
    echo "🏗️  $TARGET with Xcode $xcode_version..."
  elif [ "$ACTION" == "test" ]; then
    echo "🛠️  $TARGET with Xcode $xcode_version..."

    if [ -n "$VERBOSE_OUTPUT" ]; then
      extra_args="--test_output=all"
    else
      extra_args="--test_output=errors"
    fi
  fi

  bazel clean
  bazel $ACTION $TARGET --xcode_version $xcode_version --ios_sdk_version $sdk_version --ios_simulator_device "iPhone 6" $extra_args $verbosity_flags "${POSITIONAL[@]:3}"
}

# Usage: kill_process_mercilessly <regex>
#
# Tries to kill a process whose name ends with a string matching the given
# regex and does so repeatedly if it shows any signs of restarting itself.
function kill_process_mercilessly() {
  local -r regex="$1"
  local -r max_wait_secs=10

  while : ; do
    processname=$(ps -xc -o command | grep -E "${regex}$" | head -1)
    if [[ -z "$processname" ]]; then
      break
    fi
    killed=0
    killtime="$(date +%s)"
    waittime="$killtime"
    set +e
    until [[ "$killed" -ne 0 || \
        "$(("$waittime" - "$killtime"))" -ge "$max_wait_secs" ]]; do
      /usr/bin/killall -9 "$processname" >/dev/null 2>&1
      killed="$?"
      waittime="$(date +%s)"
    done
    set -e
  done
}

# Usage: reset_simulator_service
#
# If you have a CI service that switches between multiple Xcode versions,
# sometimes simulators used by the actool/ibtool daemon associated with the
# previous version will not properly shut down after a switch. If the variable
# SHOULD_RESET_SIMULATORS is set in your environment, then this function is
# called at the beginning of actoolwrapper and ibtoolwrapper to force the
# simulator process to be killed.
function reset_simulator_service() {
  kill_process_mercilessly "com\.apple\.CoreSimulatorService"
}

if [ -n "$KOKORO_BUILD_NUMBER" ]; then
  xcodes=( 8.3.3 9.0 9.1 9.2 )
  sdks=( 10.3 11.0 11.1 11.2 )
  # Runs our tests on every available Xcode installation.
  for ((i=0; i<${#xcodes[*]}; i++));
  do
    if [ -n "$MIN_XCODE_VERSION" ]; then
      if [ "$(version_as_number ${xcodes[i]})" -lt "$MIN_XCODE_VERSION" ]; then
        continue
      fi
    fi

    # if [ "$ACTION" == "test" ]; then
      sudo xcode-select --switch /Applications/Xcode_${xcodes[i]}.app/Contents/Developer
      reset_simulator_service
      killall "Simulator"
      xcodebuild -version
      xcrun simctl list
      xcodebuild -showsdks
      # xcrun simctl create 'iPhone 6' com.apple.CoreSimulator.SimDeviceType.iPhone-6 com.apple.CoreSimulator.SimRuntime.iOS-10-3
      # Resolves the following crash when switching Xcode versions:
      # "Failed to locate a valid instance of CoreSimulatorService in the bootstrap"
      launchctl remove com.apple.CoreSimulator.CoreSimulatorService || true
    # fi

    invoke_bazel ${xcodes[i]} ${sdks[i]}
  done
else
  # Run against whichever Xcode is currently selected.
  selected_xcode_developer_path=$(xcode-select -p)
  selected_xcode_contents_path=$(dirname "$selected_xcode_developer_path")

  xcode_version=$(cat "$selected_xcode_contents_path/version.plist" \
    | grep "CFBundleShortVersionString" -A1 \
    | grep string \
    | cut -d'>' -f2 \
    | cut -d'<' -f1)
  if [ -n "$MIN_XCODE_VERSION" ]; then
    xcode_version_as_number="$(version_as_number $xcode_version)"

    if [ "$xcode_version_as_number" -lt "$MIN_XCODE_VERSION" ]; then
      echo "The currently selected Xcode version ($xcode_version_as_number) is less than the desired version ($MIN_XCODE_VERSION)."
      echo "Stopping execution..."
      exit 1
    fi
  fi

  invoke_bazel $xcode_version
fi
