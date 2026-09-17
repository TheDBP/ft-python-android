# ft-python-android — one-shot build image.
#
# Bakes the exact, pinned toolchain that BUILD.md's "clean-run verdict" proved
# (NDK r27c, AOSP flang clang-r522817, Chaquopy @f004380, OpenBLAS 0.3.34,
# numpy 2.5.1, scipy 1.18.0, a free-threaded host CPython 3.14t via uv), then
# runs all five stages and drops the wheels + Chaquopy target into /out.
#
# Build (context = repo root):   docker build -f docker/Dockerfile -t ft-python-android .
# Run:                           docker run --rm -v "$PWD/out:/out" ft-python-android
#
# This image is large by nature — it is a cross-compile toolchain (NDK + full
# flang prebuilt are several GB each). That is the price of "no host setup".
FROM ubuntu:24.04

# ---- pinned versions (override at build time with --build-arg) ----------------
ARG PY_VERSION=3.14.7
ARG NDK_VERSION=27.3.13750724
ARG NDK_ZIP=android-ndk-r27c-linux.zip
ARG CHAQUOPY_REF=f004380
ARG OPENBLAS_VERSION=0.3.34
ARG NUMPY_VERSION=2.5.1
ARG SCIPY_VERSION=1.18.0

# ---- fixed layout (the stage scripts hard-code these under $FT_ROOT) ----------
ENV FT_ROOT=/opt/ft-build \
    FLANG_CACHE=/opt/flang-cache \
    DEBIAN_FRONTEND=noninteractive
ENV NDK=${FT_ROOT}/android-sdk/ndk/${NDK_VERSION} \
    ANDROID_HOME=${FT_ROOT}/android-sdk \
    CHAQUOPY_ROOT=${FT_ROOT}/chaquopy \
    PY_VERSION=${PY_VERSION}

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# ---- host build tooling -------------------------------------------------------
# gettext-base -> envsubst (renders the meson cross files); patchelf -> meson-python
# wheel fixups; zip -> stage-5 packaging.
# cmake + autotools -> stage 7: the four codecs and libsndfile are cmake projects,
# libffi is autotools. Neither is implied by build-essential.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make git wget curl unzip zip xz-utils \
        ca-certificates patch patchelf pkg-config gettext-base file \
        cmake autoconf automake libtool \
    && rm -rf /var/lib/apt/lists/*

# ---- uv + a free-threaded host CPython 3.14t + the build venv ------------------
# The buildvenv provides the host build tools AND the python3.14t that the
# CPython Android build uses as its build-python (ABI must match the target).
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
RUN uv python install "${PY_VERSION%.*}t" \
    && uv venv --python "${PY_VERSION%.*}t" "${FT_ROOT}/buildvenv" \
    && uv pip install --python "${FT_ROOT}/buildvenv/bin/python" \
        pip build meson meson-python ninja "cython>=3.2.0,<3.3.0" wheel \
    && uv pip install --python "${FT_ROOT}/buildvenv/bin/python" \
        "numpy==${NUMPY_VERSION}" "pybind11>=2.13.2,<3.1.0" "pythran>=0.18.1,<0.19.0"

# ---- Android NDK r27c (direct zip; stub package.xml so android-env.sh is happy) -
RUN mkdir -p "${FT_ROOT}/android-sdk/ndk" \
    && cd "${FT_ROOT}" \
    && wget -q "https://dl.google.com/android/repository/${NDK_ZIP}" \
    && unzip -q "${NDK_ZIP}" && rm "${NDK_ZIP}" \
    && mv android-ndk-* "${NDK}" \
    && touch "${NDK}/package.xml"

# ---- Android flang-new toolchain (the Fortran-for-Android compiler) ------------
# Assembled from the termux ndk-toolchain-clang-with-flang r27c release, EXACTLY as
# cibuildwheel's fortran_shim.py does (the mechanism that actually populated the
# working WSL build's flang cache). The AOSP gitiles `+archive` URL that used to be
# here TRUNCATES on that huge tree and ships NO flang, so scipy failed at meson with
# "Unknown compiler". See toolchain/provision-flang.sh for the full story.
# flang-rtlibs is three symlinks into the assembled Android sysroot.
COPY toolchain/provision-flang.sh /tmp/provision-flang.sh
RUN bash /tmp/provision-flang.sh \
    && mkdir -p "${FT_ROOT}/flang-rtlibs" && cd "${FT_ROOT}/flang-rtlibs" \
    && for l in libFortranRuntime libFortranDecimal libFortran_main; do \
         ln -sf "${FLANG_CACHE}/flang-android-r27c/sysroot/usr/lib/aarch64-linux-android/$l.a" . ; \
       done

# ---- Chaquopy checkout + the free-threading enablement patch ------------------
COPY chaquopy/ft-enable.patch /tmp/ft-enable.patch
RUN git clone https://github.com/chaquo/chaquopy "${CHAQUOPY_ROOT}" \
    && git -C "${CHAQUOPY_ROOT}" checkout "${CHAQUOPY_REF}" \
    && git -C "${CHAQUOPY_ROOT}" apply /tmp/ft-enable.patch

# ---- source trees (the drivers cd into these exact paths) ---------------------
RUN mkdir -p "${FT_ROOT}/openblas-build" \
    && cd "${FT_ROOT}/openblas-build" \
    && wget -qO- "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz" \
        | tar xz
# Fetch the numpy/scipy SDISTS directly from PyPI. We only need the source
# tarballs; `pip download --no-binary` was the wrong tool here because it runs the
# packages' build backend to generate metadata, and scipy's meson configure needs
# a Fortran compiler that isn't on PATH at image-build time (numpy passed, scipy
# did not). urllib + the PyPI JSON API fetches the exact pinned sdist with no build
# machinery involved. Same source pip would resolve; fully reproducible.
RUN mkdir -p "${FT_ROOT}/src" && cd "${FT_ROOT}/src" \
    && "${FT_ROOT}/buildvenv/bin/python" -c "import json,urllib.request as u;[u.urlretrieve(next(x['url'] for x in json.load(u.urlopen('https://pypi.org/pypi/%s/%s/json'%(n,v)))['urls'] if x['packagetype']=='sdist'),'%s-%s.tar.gz'%(n,v)) for n,v in [('numpy','${NUMPY_VERSION}'),('scipy','${SCIPY_VERSION}')]]" \
    && tar xf "numpy-${NUMPY_VERSION}.tar.gz" \
    && tar xf "scipy-${SCIPY_VERSION}.tar.gz"

# ---- the repo recipe (scripts are the source of truth) ------------------------
COPY . /src
# ! FIND, NOT A LIST OF DIRECTORIES. This line used to name seven directories
#   explicitly, and by the time the chart and audio stages existed it was missing both
#   of them - a safety net with holes precisely where the newest, least-exercised code
#   was. It went unnoticed because COPY preserves the modes git records, so the net was
#   never load-bearing. Name what you want excluded, not what you want included: the set
#   that grows is the one you forget to update.
RUN find /src -name '*.sh' -exec chmod +x {} +

VOLUME ["/out"]
ENTRYPOINT ["/src/docker/build-all.sh"]
