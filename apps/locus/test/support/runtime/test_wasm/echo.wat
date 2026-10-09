;; A reagent whose `compute` answers its input unchanged: the JSON it was
;; given is the JSON it returns, so a run of it completes with a known
;; output. The canonical ABI of `cyfr:reagent/compute@0.1.0`: the export
;; takes the string's pointer and length and answers a pointer to a return
;; area holding the result string's pointer and length.
;;
;; To regenerate:
;;   wat2wasm echo.wat -o echo.core.wasm
;;   wasm-tools component embed ../../../../../wit/reagent --world reagent echo.core.wasm -o echo.embedded.wasm
;;   wasm-tools component new echo.embedded.wasm -o echo.wasm
(module
  (memory (export "memory") 1)
  (global $heap (mut i32) (i32.const 1024))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 8) (local.get $ptr))
    (i32.store (i32.const 12) (local.get $len))
    (i32.const 8)))
