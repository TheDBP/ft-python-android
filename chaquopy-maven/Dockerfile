# chaquopy-maven — the PATCHED Chaquopy 17.0.1 Gradle plugin + runtime for free-threaded
# CPython 3.14t, published to a local file maven an app can point its Gradle build at.
#
# The main image (docker/Dockerfile) builds the interpreter TARGET and the wheels. Stock
# Chaquopy ships only GIL builds, so an app also needs a plugin + runtime that know about
# `3.14t` - that is what this image builds. Recipe: Chaquopy @f004380 + chaquopy-ALL.patch
# (free-threading in buildSrc / gradle plugin / runtime, Cython 3.1.x fixes, the AssetPath
# parent fix, target/python/build.sh), then `gradlew :runtime:publish :gradle:publish`.
#
# Input : a Chaquopy TARGET (the main image's /out/target: target-<ver>-0-*.zip + .pom).
#         The target zip carries include/python3.14t and jniLibs/arm64-v8a/libpython3.14t.so,
#         which is everything the runtime links against - no CPython build happens here.
# Output: /out/maven  (plugin + runtime + that target, one file maven)
#
# Build (context = this folder):  docker build -t ft-chaquopy-maven chaquopy-maven
# Run:  docker run --rm -v "$PWD/out/target:/in:ro" -v "$PWD/out:/out" ft-chaquopy-maven
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG CHAQUOPY_REF=f004380e16445b7ac935dfc69ada1a772e0804e0
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-16111833_latest.zip
ARG CMDLINE_TOOLS_SHA256=0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8
ARG NDK_VERSION=27.3.13750724
ARG CMAKE_VERSION=3.22.1
ARG PLATFORM=android-36
ARG CYTHON_VERSION=3.1.8

# JDK 11 runs Chaquopy's Gradle 7.0.2 (it rejects 17: "Unsupported class file major version
# 61"); JDK 17 runs the current sdkmanager (it rejects 11). Python 3.12 (non-free-threaded)
# hosts Cython - 3.1.8 is the one version that both knows 3.14 and survives Chaquopy's sources.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-11-jdk-headless openjdk-17-jdk-headless \
        git unzip wget ca-certificates python3 python3-venv python3-dev binutils file \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64 \
    JDK17=/usr/lib/jvm/java-17-openjdk-amd64 \
    CHAQUOPY=/opt/chaquopy

RUN mkdir -p "$ANDROID_HOME/cmdline-tools" && cd /tmp \
    && wget -q "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" \
    && echo "${CMDLINE_TOOLS_SHA256}  ${CMDLINE_TOOLS_ZIP}" | sha256sum -c - \
    && unzip -q "${CMDLINE_TOOLS_ZIP}" && mv cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
    && rm -f "${CMDLINE_TOOLS_ZIP}" \
    && SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
    && (yes | JAVA_HOME="$JDK17" "$SDKM" --licenses >/dev/null) \
    && JAVA_HOME="$JDK17" "$SDKM" "platforms;${PLATFORM}" "cmake;${CMAKE_VERSION}" "ndk;${NDK_VERSION}" >/dev/null \
    && test -x "$ANDROID_HOME/cmake/${CMAKE_VERSION}/bin/cmake" \
    && test -d "$ANDROID_HOME/ndk/${NDK_VERSION}/build/cmake"

RUN python3 -m venv /opt/cythonenv && /opt/cythonenv/bin/pip install --no-cache-dir "Cython==${CYTHON_VERSION}" \
    && /opt/cythonenv/bin/cython --version
ENV PATH=/opt/cythonenv/bin:$PATH

# The runtime's :compilePython-3.14 task runs a HOST `python3.14` (a GIL build) to byte-compile
# the bootstrap modules. The hand build used deadsnakes' /usr/bin/python3.14 = 3.14.6; a PPA
# cannot be pinned, so install exactly that version with uv instead.
ARG HOST_PY314=3.14.6
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /usr/local/bin/uv
RUN UV_PYTHON_INSTALL_DIR=/opt/uv-python uv python install "${HOST_PY314}" \
    && ln -s "$(UV_PYTHON_INSTALL_DIR=/opt/uv-python uv python find "${HOST_PY314}")" /usr/local/bin/python3.14 \
    && python3.14 -c 'import sys,sysconfig; v=sys.version.split()[0]; assert v=="'"${HOST_PY314}"'", v; assert not sysconfig.get_config_var("Py_GIL_DISABLED"); print("host python3.14", v, "GIL")'

# The checkout + THE patch. `git apply` fails the image build if the patch does not apply,
# which is the point: a patch that drifted from its base must not publish anything.
COPY chaquopy-ALL.patch /tmp/chaquopy-ALL.patch
RUN git clone https://github.com/chaquo/chaquopy "$CHAQUOPY" \
    && git -C "$CHAQUOPY" checkout "${CHAQUOPY_REF}" \
    && git -C "$CHAQUOPY" apply /tmp/chaquopy-ALL.patch \
    && grep -q "ndk_version=${NDK_VERSION}" "$CHAQUOPY/target/android-env.sh"

COPY build-maven.sh /usr/local/bin/build-maven.sh
RUN chmod 755 /usr/local/bin/build-maven.sh
ENTRYPOINT ["/usr/local/bin/build-maven.sh"]
