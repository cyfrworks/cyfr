;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose `compute` is lifted async without a callback: the
;; component-model async stackful ABI, in which the guest's task runs on a
;; stack of its own and answers through `task.return`. Refused for
;; `cm-async-stackful` (`Prima.ComponentFeatures`). The ABI is a form of
;; the async lift, so the validator admits it only with `cm-async` on too;
;; it uses no other refused feature. The validator's defaults leave
;; `cm-async-stackful` off, so the check answers it as invalid
;; WebAssembly. A component text, built by `build.sh` (README.md).
(component
  (core module $m
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "compute") (param i32 i32)))
  (core instance $i (instantiate $m))
  (func $compute async (param "input" string) (result string)
    (canon lift (core func $i "compute") async
      (memory (core memory $i "memory")) (realloc (core func $i "cabi_realloc"))))
  (instance $compute-instance (export "compute" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance)))
