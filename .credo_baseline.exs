# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Credo findings the tree had when .credo.exs enabled its checks, read
# by .credo.exs: one {check, file, trigger, count} row per check, file and
# trigger, where count is how many times that check reports that trigger in
# that file. This list only shrinks: fixing a finding lowers or removes its
# row in the same change, and `mix credo --strict` fails while a row allows
# more findings than the tree has, or the tree has a finding no row allows.
[
  {Credo.Check.Warning.LeakyEnvironment,
   "apps/cyfr/test/integration/runtime/worker_service_test.exs", "System.cmd", 1},
  {Credo.Check.Warning.LeakyEnvironment, "apps/cyfr/test/sanctum/gate/admission_latency_test.exs",
   "System.cmd", 2},
  {Credo.Check.Warning.LeakyEnvironment, "apps/cyfr/test/support/step_bench.ex", "System.cmd", 2},
  {Credo.Check.Warning.UnsafeToAtom, "apps/cyfr/test/sanctum/gate/provider_contract_test.exs",
   "Module.concat", 1},
  {Credo.Check.Warning.UnsafeToAtom, "apps/cyfr/test/sanctum/permission_vocabulary_test.exs",
   "String.to_atom", 2}
]
