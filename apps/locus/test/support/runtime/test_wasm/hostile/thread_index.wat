;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; `sync_lift` beside a `thread.index` builtin, which answers the index of
;; the component-model thread calling it. Refused for `cm-threading` alone
;; (`Prima.ComponentFeatures`): the validator admits it with that feature
;; on and every other refused feature off. Its defaults leave the feature
;; off, so the check answers it as invalid WebAssembly. A component text,
;; built by `build.sh` (README.md).
(component
  (core func $index (canon thread.index))
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
