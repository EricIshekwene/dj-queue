#!/bin/zsh
# Runs the test suite. With Xcode installed plain `swift test` works; with only the
# Command Line Tools, Swift Testing needs its framework paths spelled out.
set -e
cd "$(dirname "$0")/.."
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  U=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  exec swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $U "$@"
else
  exec swift test "$@"
fi
