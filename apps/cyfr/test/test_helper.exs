# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# :s3_integration requires MinIO, and :public_dns the public resolver;
# each runs only when explicitly selected. A real build needs its
# toolchain: :requires_cargo_component runs where `cargo-component` is on
# PATH, as it is in CI, and is excluded, and said so, where it is not.
toolchain_excludes =
  if System.find_executable("cargo-component"), do: [], else: [:requires_cargo_component]

if toolchain_excludes != [] do
  IO.puts("cyfr: skipping #{inspect(toolchain_excludes)} — toolchain not found on PATH")
end

# :cluster is the two-node suite (`test/cluster`): two `:peer` nodes, each
# running the whole application against one Postgres and one object store.
# It costs two operating-system processes and a full boot each, and it
# needs a database of its own, so it runs only when it is asked for.
# :benchmark is the admission latency matrix (`Sanctum.Gate.AdmissionLatencyTest`):
# minutes of timed samples against committed rows, run alone with
# `--only benchmark` so nothing else competes for the pool it measures.
# :boundary_plant is the Boundary compiler's planted violations
# (`Cyfr.BoundariesTest.CompilerPlants`): each is a forced compile of a
# copy of the tree, run once by the gate's static leg.
# The other adapter's tests are excluded too (`Arca.Test.Adapter`).
ExUnit.configure(
  exclude:
    [:cluster, :s3_integration, :public_dns, :benchmark, :boundary_plant] ++
      toolchain_excludes ++ Arca.Test.Adapter.exclusions()
)

# The suite runs from the umbrella root, where the runtime's worker service is
# up beside CYFR: its listener and CYFR's host API listener each bound a
# port of the system's choosing, and here each is pointed at the other,
# so every run the suite dispatches crosses the wire as a deployment's
# does (`Cyfr.Test.RuntimeService`).
Cyfr.Test.RuntimeService.wire!()

# The Locus builds service is up beside them too, serving builds on a
# loopback port of its own once given its key; a test that builds points
# this server at it (`Cyfr.Test.LocusService.configure!/0`), and the build
# crosses the build wire as a deployment's does. An umbrella run takes the
# apps in dependency order (prima, arca, locus, sanctum, cyfr), so Locus's
# own suite has run in this VM before this one; the service stops serving
# when this suite ends, leaving Locus as this suite found it.
Cyfr.Test.LocusService.serve!()
ExUnit.after_suite(fn _ -> Cyfr.Test.LocusService.stop!() end)

# The platform settings the boot installed, with the suite's own values
# over the roster's defaults (`Cyfr.Test.Settings.suite/0`); a test sets
# one through `Cyfr.Test.Settings.put/2`.
Cyfr.Test.Settings.install!()

# The storage roots (with a copy of the shipped AQUA template in the
# throwaway seed tree, so template reads stay real without the suite
# touching the repo's own seed/), the schema check, the sandbox mode and
# the seeded athanors, as every database app's suite has them.
Arca.Test.SuiteBoot.boot!(seed: &Sanctum.TestContext.seed_athanors!/0, seed_templates: ["aqua"])

# The suite must never write into the repo's own trees: every storage root —
# the suite DB and the seed tree included — is under tmp (config/test.exs),
# so an entry appearing under the repo's data/ or seed/ means a test reached
# the real filesystem around the tmp roots.
#
# The check is on what the run ADDS, not on what is there. A developer who
# has run the server locally has real athanor trees under data/athanors/,
# and failing the run for them would make the exit code useless on exactly
# the machine that most needs it — green and red would look the same. On a
# fresh checkout the snapshot is empty, so any stray write still fails.
repo_root = Path.expand("../../..", __DIR__)
watched_dirs = ["data", "data/athanors", "seed", "seed/components", "seed/aqua"]

entries_under = fn dir ->
  path = Path.join(repo_root, dir)
  if File.dir?(path), do: MapSet.new(File.ls!(path)), else: MapSet.new()
end

before_suite = Map.new(watched_dirs, &{&1, entries_under.(&1)})

ExUnit.after_suite(fn _ ->
  for dir <- watched_dirs do
    added = MapSet.difference(entries_under.(dir), Map.fetch!(before_suite, dir))

    if MapSet.size(added) > 0 do
      IO.puts(:stderr, "\n** the suite wrote into #{dir}/: #{inspect(MapSet.to_list(added))}")
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end)

ExUnit.start()
