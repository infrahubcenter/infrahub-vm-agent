FROM golang:1.26-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsystemd-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/vm-agent .

# Collect libsystemd.so.0 and the libraries it needs (not glibc itself,
# which the runtime base already has) into one flat folder. The journal
# reader (go-systemd sdjournal) dlopen()s libsystemd at runtime, so this is
# the only native dependency.
RUN mkdir -p /out/lib && \
    lib=$(ls /usr/lib/*/libsystemd.so.0) && \
    for f in "$lib" $(ldd "$lib" | awk '/=>/ {print $3}'); do \
      case "$(basename "$f")" in libc.so*|libm.so*|ld-linux*|libpthread.so*|libdl.so*|librt.so*) continue ;; esac; \
      cp -L "$f" /out/lib/; \
    done && ls -la /out/lib

# distroless/base: glibc, CA certificates and tzdata only -- no shell or
# package manager -- instead of a full debian:bookworm-slim. Still runs as
# root, same justification as docker-agent's own Dockerfile: this agent
# reads host-owned files (the bind-mounted journal, /var/log, /proc and the
# root filesystem for storage stats) whose ownership varies host-to-host.
FROM gcr.io/distroless/base-debian12
COPY --from=build /out/lib/ /opt/infrahub/lib/
ENV LD_LIBRARY_PATH=/opt/infrahub/lib
COPY --from=build /out/vm-agent /vm-agent
ENTRYPOINT ["/vm-agent"]
