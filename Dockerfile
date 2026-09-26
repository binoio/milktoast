# Containerized test run for the portable remux engine.
#
# MilktoastCore is Foundation-only — the ffprobe JSON model, the codec policy, the
# ffmpeg argument builder, the progress parser, and the cache logic all compile
# on Linux. ffmpeg is installed so the integration tests do real remuxes here
# too; the SwiftUI app target is excluded from the package graph on non-Apple
# hosts (see Package.swift).
FROM swift:6.1-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /package

COPY Package.swift ./
COPY CXattr ./CXattr
COPY Core ./Core
COPY CLI ./CLI
COPY Tests ./Tests

CMD ["swift", "test"]
