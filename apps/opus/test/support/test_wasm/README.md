# Test WASM Files

This directory contains pre-compiled WASM binaries for testing Opus execution.

## Files

- `sum.wasm` - Simple function that adds two i32 integers
- More test files will be added as needed

## Source

The WASM files are generated from WAT (WebAssembly Text) format.

### sum.wat
```wat
(module
  (func $sum (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add)
  (export "sum" (func $sum)))
```

To regenerate: `wat2wasm sum.wat -o sum.wasm`
