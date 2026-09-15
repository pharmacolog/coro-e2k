# Стенд: OpenE2K binutils (as/ld для e2k) + qemu-e2k linux-user с патчем
# tools/qemu-e2k-user-hwstacks.patch. Сборка ~15 мин на 12 ядрах.
#
#   docker build -t coro-e2k-lab -f tools/Dockerfile .
#   docker run --rm -v "$PWD":/src -w /src coro-e2k-lab make check
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git python3 python3-venv ninja-build meson pkg-config \
    libglib2.0-dev libpixman-1-dev zlib1g-dev flex bison texinfo \
    libgmp-dev libmpfr-dev libzstd-dev ca-certificates file && \
    rm -rf /var/lib/apt/lists/*
COPY tools/qemu-e2k-user-hwstacks.patch tools/build-toolchain.sh /tmp/tools/
RUN sh /tmp/tools/build-toolchain.sh /opt/e2k
ENV PATH=/opt/e2k/bin:$PATH
WORKDIR /src
