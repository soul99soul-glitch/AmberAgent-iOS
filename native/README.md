# Rust Native Components

Cargo workspace for AmberAgent's parsers, transformers, crypto, and tokenizer.
The `amber-ffi` crate exposes those capabilities through the
`AmberNative.xcframework` consumed by the iOS/KMP build; component crates may
also retain JNI bindings for other consumers.

## Layout

```
native/
├── Cargo.toml                    workspace manifest
├── amber-ffi/                    stable C ABI exported to Apple platforms
├── office-parsers/               document extraction
├── markdown-parser/              pulldown-cmark + packed binary AST
├── highlight-parser/             tree-sitter syntax highlighting
├── tokenizer/                    model token counting
├── sync-crypto/                  encrypted sync primitives
├── regex-transformer/            rule-based text transformations
├── reader-extractor/             readable-content extraction
├── ...                           additional shared native components
└── build-xcframework.sh          device/simulator XCFramework builder
```

## Local development

```bash
# Native-only sanity build (no Android linking)
cargo build --release

# Run native unit tests
cargo test --workspace

# Lint
cargo clippy --workspace --all-targets -- -D warnings

# Format check
cargo fmt --check
```

## Apple framework build

```bash
# Build native device and simulator slices.
./native/build-xcframework.sh

# Link the framework into the KMP simulator artifact.
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
```

## Hard constraints

- **Bounded memory**: Native calls must work with O(input size) memory.
- **Panic containment**: Never unwind across the C ABI boundary.
- **Output stability**: Each component must preserve the checked-in golden
  corpus in `native/<component>/tests/corpus/`.
