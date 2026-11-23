name: Rust
detect: Cargo.toml
language: Rust
package_manager: cargo
install: cargo fetch
dev: cargo run
check: cargo fmt --check && cargo clippy -- -D warnings && cargo test
check_changed: cargo fmt --check && cargo clippy -- -D warnings && cargo test
note: cargo has no test selection; split crates to keep it fast
test_one: cargo test test_x
