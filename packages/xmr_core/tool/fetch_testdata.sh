#!/bin/sh
# Downloads third-party test fixtures (not committed): P2Pool share dumps and
# a sample share from the upstream P2Pool test suite. Data only, used by
# test/p2pool_*_test.dart; tests skip when the files are absent.
set -e
cd "$(dirname "$0")/../test/fixtures"
BASE=https://raw.githubusercontent.com/SChernykh/p2pool/master/tests/src
for f in block.dat sidechain_dump.dat.xz sidechain_dump_mini.dat.xz sidechain_dump_nano.dat.xz; do
  [ -f "$f" ] || [ -f "${f%.xz}" ] || curl -sfL -o "$f" "$BASE/$f"
done
for f in *.xz; do [ -f "$f" ] && xz -df "$f"; done
ls -la
