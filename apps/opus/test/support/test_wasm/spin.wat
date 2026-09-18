;; A reagent whose `compute` never returns: it spins in a tight loop on its
;; native thread, ignoring every deadline, so the runner's watchdog is the
;; only thing that ends it. The canonical ABI of
;; `cyfr:reagent/compute@0.1.0` is satisfied in shape only: the export takes
;; the string's pointer and length and would answer a return-area pointer.
;;
;; To regenerate:
;;   wat2wasm spin.wat -o spin.core.wasm
;;   wasm-tools component embed ../../../../../wit/reagent --world reagent spin.core.wasm -o spin.embedded.wasm
;;   wasm-tools component new spin.embedded.wasm -o spin.wasm
(module
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (i32.const 1024))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param i32 i32) (result i32)
    (loop $spin (br $spin))
    (unreachable)))
