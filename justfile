VERSION := `git rev-parse HEAD`

default:
  @just --list --unsorted --color=always | rg -v "    default"

clippy:
  #rustup component add clippy --toolchain nightly
  cargo +nightly clippy --workspace
  cargo +nightly clippy --no-default-features --features=rustls-tls

fmt:
  #rustup component add rustfmt --toolchain nightly
  rustfmt +nightly --edition 2021 $(find . -type f -iname *.rs)

doc:
  RUSTDOCFLAGS="--cfg docsrs" cargo +nightly doc --lib --workspace --features=derive,ws,oauth,jsonpatch,client,derive,runtime,admission,k8s-openapi/v1_24 --open

# Unit tests
test:
  cargo test --lib --all
  cargo test --doc --all
  cargo test -p kube-examples --examples
  cargo test -p kube --lib --no-default-features --features=rustls-tls,ws,oauth
  cargo test -p kube --lib --no-default-features --features=native-tls,ws,oauth
  cargo test -p kube --lib --no-default-features --features=openssl-tls,ws,oauth
  cargo test -p kube --lib --no-default-features

test-integration:
  kubectl delete pod -lapp=kube-rs-test
  cargo test --lib --all -- --ignored # also run tests that fail on github actions
  cargo test -p kube --lib --features=derive,runtime -- --ignored
  cargo test -p kube-client --lib --features=rustls-tls,ws -- --ignored
  cargo run -p kube-examples --example crd_derive
  cargo run -p kube-examples --example crd_api

coverage:
  cargo tarpaulin --out=Html --output-dir=.
  #xdg-open tarpaulin-report.html

deny:
  # might require rm Cargo.lock first to match CI
  cargo deny --workspace --all-features check bans licenses sources

readme:
  rustdoc README.md --test --edition=2021

e2e: dapp
  ls -lah e2e/
  docker build -t clux/kube-dapp:{{VERSION}} e2e/
  k3d image import clux/kube-dapp:{{VERSION}} --cluster main
  sed -i 's/latest/{{VERSION}}/g' e2e/deployment.yaml
  kubectl apply -f e2e/deployment.yaml
  sed -i 's/{{VERSION}}/latest/g' e2e/deployment.yaml
  kubectl get all -n apps
  kubectl describe jobs/dapp -n apps
  kubectl wait --for=condition=complete job/dapp -n apps --timeout=50s || kubectl logs -f job/dapp -n apps
  kubectl get all -n apps
  kubectl wait --for=condition=complete job/dapp -n apps --timeout=10s || kubectl get pods -n apps | grep dapp | grep Completed

dapp:
  #!/usr/bin/env bash
  docker run \
    -v cargo-cache:/root/.cargo/registry \
    -v "$PWD:/volume" -w /volume \
    --rm -it clux/muslrust:stable cargo build --release -p e2e
  cp target/x86_64-unknown-linux-musl/release/dapp e2e/dapp
  chmod +x e2e/dapp

k3d:
  k3d cluster create main --servers 1 --agents 1 --registry-create main \
    --k3s-arg "--no-deploy=traefik@server:*" \
    --k3s-arg '--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@agent:*' \
    --k3s-arg '--kubelet-arg=eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%@agent:*'

# Bump the msrv of kube; "just bump-msrv 1.60.0"
bump-msrv msrv:
  #!/usr/bin/env bash
  oldmsrv="$(rg "rust-version = \"(.*)\"" -r '$1' kube/Cargo.toml)"
  fastmod -m -d . --extensions toml "rust-version = \"$oldmsrv\"" "rust-version = \"{{msrv}}\""
  # sanity
  if [[ $(cat ./*/Cargo.toml | grep "rust-version" | uniq | wc -l) -gt 1 ]]; then
    echo "inconsistent rust-version keys set in various kube-crates:"
    rg "rust-version" ./*/Cargo.toml
    exit 1
  fi
  fullmsrv="{{msrv}}"
  shortmsrv="${fullmsrv::-2}" # badge can use a short display version
  badge="[![Rust ${shortmsrv}](https://img.shields.io/badge/MSRV-${shortmsrv}-dea584.svg)](https://github.com/rust-lang/rust/releases/tag/{{msrv}})"
  sd "^.+badge/MSRV.+$" "${badge}" README.md
  sd "${oldmsrv}" "{{msrv}}" .devcontainer/Dockerfile
  cargo msrv

# Increment the Kubernetes feature version from k8s-openapi for tests; "just bump-k8s"
bump-k8s:
  #!/usr/bin/env bash
  current=$(cargo tree --format "{f}" -i k8s-openapi | head -n 1)
  next=${current::-2}$((${current:3} + 1))
  fastmod -m -d . --extensions toml "$current" "$next"
  fastmod -m "$current" "$next" -- README.md
  fastmod -m "$current" "$next" -- justfile

# mode: makefile
# End:
# vim: set ft=make :
