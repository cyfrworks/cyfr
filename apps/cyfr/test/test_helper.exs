# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The cyfr↔opus execution flow (tagged `:requires_opus`) is the product's core
# path and ships as one BEAM. Exclude those tests only when opus is not part of
# the loaded application set — i.e. when this suite is run scoped to apps/cyfr
# alone. An umbrella-root run (local or CI) has opus loaded and includes them.
#
# `:requires_opus_modules` is the weaker requirement: the test only calls into
# opus MODULES (tool providers) without needing the running app — e.g. the
# tool-classification and consent-shape tests that enumerate every provider's
# actions. Those run whenever the opus code is loadable (a fresh umbrella
# compile leaves it loaded) and are excluded when it isn't (a cached
# app-scoped run), instead of crashing on an UndefinedFunctionError.
excludes =
  Enum.concat(
    if(is_nil(Application.spec(:opus)), do: [:requires_opus], else: []),
    if(Code.ensure_loaded?(Opus.MCP), do: [], else: [:requires_opus_modules])
  )

if excludes != [], do: ExUnit.configure(exclude: excludes)

# The tmp storage roots configured in config/test.exs.
for key <- [:base_path, :bundle_path] do
  File.mkdir_p!(Application.fetch_env!(:cyfr, key))
end

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

# The suite must never write into the repo's own component trees: every
# storage root is under tmp (config/test.exs), and the only thing tracked
# under `components/` is the seed bundle. A stray write here would mean a
# test reached the real filesystem around the tmp roots.
#
# The check is on what the run ADDS, not on what is there. A developer who has
# run the server locally has their own athanor tree under `components/`, and
# failing the run for it would make the exit code useless on exactly the
# machine that most needs it — green and red would look the same. On a fresh
# checkout the snapshot holds only `_bundle`, so any stray write still fails.
repo_root = Path.expand("../../..", __DIR__)
component_dirs = ["components", "apps/cyfr/components", "apps/opus/components"]

entries_under = fn dir ->
  path = Path.join(repo_root, dir)
  if File.dir?(path), do: MapSet.new(File.ls!(path)), else: MapSet.new()
end

before_suite = Map.new(component_dirs, &{&1, entries_under.(&1)})

ExUnit.after_suite(fn _ ->
  for dir <- component_dirs do
    added = MapSet.difference(entries_under.(dir), Map.fetch!(before_suite, dir))

    if MapSet.size(added) > 0 do
      IO.puts(:stderr, "\n** the suite wrote into #{dir}/: #{inspect(MapSet.to_list(added))}")
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end)

ExUnit.start()
