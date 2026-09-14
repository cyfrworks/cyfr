# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Include :requires_opus tests when the Opus application is loaded.
# :requires_opus_modules needs only loadable Opus code.
# :s3_integration requires MinIO and runs only when explicitly selected.
# :requires_local_docs runs only when the gitignored CLAUDE.md exists.
excludes =
  [:s3_integration] ++
    Enum.concat(
      if(is_nil(Application.spec(:opus)), do: [:requires_opus], else: []),
      if(Code.ensure_loaded?(Opus.MCP), do: [], else: [:requires_opus_modules])
    ) ++
    if File.exists?(Path.expand("../../../CLAUDE.md", __DIR__)),
      do: [],
      else: [:requires_local_docs]

ExUnit.configure(exclude: excludes)

# Owned by the test-runner process so it outlives every test and no two
# tests race to create it. `Cyfr.Test.SourceTree` fills it lazily; see that
# module for why the architecture tests need to stop re-reading the tree.
:ets.new(Cyfr.Test.SourceTree.table(), [:named_table, :public, :set, read_concurrency: true])

# The tmp storage roots configured in config/test.exs: the tenant root, and
# the seed tree with an empty bundle plus a copy of the shipped AQUA
# template (template reads stay real without the suite touching the repo's
# own seed/).
File.mkdir_p!(Application.fetch_env!(:cyfr, :base_path))

seed_path = Application.fetch_env!(:cyfr, :seed_path)
File.mkdir_p!(Path.join(seed_path, "components"))
File.cp_r!(Path.expand("../../../seed/aqua", __DIR__), Path.join(seed_path, "aqua"))

# A suite database built from a different schema would run stale, since the
# baseline still reads as applied; refuse it before any test touches it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

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

  # The run's tmp roots do not accumulate across runs.
  File.rm_rf(Application.fetch_env!(:cyfr, :base_path))
  File.rm_rf(Application.fetch_env!(:cyfr, :seed_path))
end)

ExUnit.start()
