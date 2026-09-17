#!/bin/bash
out=$(${FT_ROOT}/buildvenv/bin/pybind11-config "$@")
# strip the build-python include (-I/usr/include/python3.14t); target include comes from the python dep
echo "$out" | sed -E "s#-I/usr/include/python[0-9.]+t?##g"
