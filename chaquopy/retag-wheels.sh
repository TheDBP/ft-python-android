#!/bin/bash
set -eu -o pipefail
# Retag cross-built wheels so Chaquopy will install them (the README's "one
# non-obvious trick", now a script instead of a sentence). meson-python tags
# with the BUILD HOST's platform; the real platform is the cross target:
#   numpy  -> android_24_arm64_v8a  (its cross file targets API 24)
#   scipy  -> android_26_arm64_v8a  (its cross file targets API 26 - Fortran)
# Requires the 'wheel' package in the buildvenv:  uv pip install ... wheel
cd "${FT_ROOT:?}/wheels"
for w in numpy-*-linux_x86_64.whl; do
  [ -e "$w" ] && python -m wheel tags --platform-tag=android_24_arm64_v8a --remove "$w"
done
for w in scipy-*-linux_x86_64.whl; do
  [ -e "$w" ] && python -m wheel tags --platform-tag=android_26_arm64_v8a --remove "$w"
done
ls *.whl
