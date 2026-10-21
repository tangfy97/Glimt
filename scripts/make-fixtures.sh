#!/bin/zsh
# Builds and runs the fixture generator. Output goes to .fixtures/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/make-fixtures scripts/MakeFixtures.swift
build/make-fixtures .fixtures
