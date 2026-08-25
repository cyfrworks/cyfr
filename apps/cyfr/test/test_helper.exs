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

# The tmp storage roots configured in config/test.exs: the tenant root, and
# the seed tree with an empty bundle plus a copy of the shipped AQUA
# template (template reads stay real without the suite touching the repo's
# own seed/).
File.mkdir_p!(Application.fetch_env!(:cyfr, :base_path))

seed_path = Application.fetch_env!(:cyfr, :seed_path)
File.mkdir_p!(Path.join(seed_path, "components"))
File.cp_r!(Path.expand("../../../seed/aqua", __DIR__), Path.join(seed_path, "aqua"))

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

# The suite must never write into the repo's own storage tree: every storage
# root — the suite DB included — is under tmp (config/test.exs), so an entry
# appearing under the repo's data/athanors/ means a test reached the real
# filesystem around the tmp roots.
#
# The check is on what the run ADDS, not on what is there. A developer who
# has run the server locally has real athanor trees under data/athanors/,
# and failing the run for them would make the exit code useless on exactly
# the machine that most needs it — green and red would look the same. On a
# fresh checkout the snapshot is empty, so any stray write still fails.
repo_root = Path.expand("../../..", __DIR__)
watched_dirs = ["data/athanors"]

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
