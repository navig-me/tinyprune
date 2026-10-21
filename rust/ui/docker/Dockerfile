FROM rust:1.98.1-bookworm AS rust
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libwebkit2gtk-4.1-dev build-essential curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev xvfb xauth imagemagick dbus-x11 fonts-dejavu-core webkit2gtk-driver python3 nodejs npm ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN cargo install tauri-driver --version 2.0.4 --locked
RUN mkdir /opt/a11y && cd /opt/a11y && npm install --save-exact axe-core@4.10.3
WORKDIR /repo
CMD ["bash", "rust/ui/docker/container.sh"]
