name: Rust
detect: Cargo.toml
language: Rust
package_manager: cargo
install: cargo fetch
dev: cargo run
check: cargo fmt --check && cargo clippy -- -D warnings && cargo test
test_one: cargo test test_x
