;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A reagent whose `compute` never returns: it spins in a tight loop,
;; asking nothing of its host, so only the run's budget ends it, which the
;; runner's engine holds it to. The canonical ABI of
;; `cyfr:reagent/compute@0.1.0` is satisfied in shape only: the export takes
;; the string's pointer and length and would answer a return-area pointer.
;;
;; Built by build.sh (README.md).
(module
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (i32.const 1024))
  (func (export "cyfr:reagent/compute@0.1.0#compute") (param i32 i32) (result i32)
    (loop $spin (br $spin))
    (unreachable)))
