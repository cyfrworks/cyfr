;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; `sync_lift` beside a `subtask.cancel` builtin marked `async`, a cancel
;; that may block and so lets the guest's task wait inside the host's
;; event loop. Refused for `cm-more-async-builtins`
;; (`Prima.ComponentFeatures`). Every builtin that feature gates is a
;; component-model async builtin, so the validator admits it only with
;; `cm-async` on too; it uses no other refused feature. The validator's
;; defaults leave `cm-more-async-builtins` off, so the check answers it as
;; invalid WebAssembly. A component text, built by `build.sh` (README.md).
(component
  (core func $cancel (canon subtask.cancel async))
  (core module $m
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32) (result i32) (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
