- Avoid unwraps or anything that can panic in Rust code; handle errors. Obviously in tests unwraps and panics are fine!
- In Rust code prefer `crate::` to `super::`; avoid `super::` in non-test code. `super::` is fine in tests.
- Avoid `pub use` on imports unless you are re-exposing a dependency so downstream consumers do not have to depend on it directly.
- Skip global state via `lazy_static!`, `Once`, or similar; prefer passing explicit context structs for any shared state.
- Prefer strong types over strings, use enums and newtypes when the domain is closed or needs validation.

## Rust Workflow Checklist

1. Run `cargo fmt`.
1. Never run `cargo fmt --all`, it will happily format submodules and leave a mess.
1. Run `cargo clippy --all --benches --tests --examples --all-features` and address warnings.
1. Execute the relevant `cargo test` or `just` targets to cover unit and end-to-end paths.
