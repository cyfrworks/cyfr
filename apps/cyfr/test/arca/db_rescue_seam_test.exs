# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DbRescueSeamTest do
  @moduledoc """
  Mechanical guard for the one spelling of "a database outage at a storage
  entry point": `Arca.Repo.Errors.with_db_rescue/2` (or `/3` for a
  justified default-returner). Style follows `Cyfr.CrossLanguageDriftTest`:
  read the sources, compare literals — a failure means "an inline rescue
  crept in, go wrap it", never a behavioural assertion.

  Value-position uses of `db_errors()` (attribute lists such as
  `Sanctum.Namespace`'s `@transient` or `Opus.CronScheduler`'s error
  rosters) are not rescue clauses and are deliberately not matched.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # A rescue clause names the roster as `e in Arca.Repo.Errors.db_errors()`;
  # value-position uses have no ` in ` before the call.
  @rescue_pattern ~r/\bin Arca\.Repo\.Errors\.db_errors\(\)/

  # The enumerated exceptions: every file allowed to keep an inline rescue,
  # with how many sites it holds and why each stays inline. Everything else
  # under apps/{cyfr,opus,locus}/lib must go through with_db_rescue.
  @allowed %{
    # The helper's own home: the moduledoc shows the raw rescue shape once,
    # as documentation of what the roster is for.
    "apps/cyfr/lib/arca/repo/errors.ex" => 1,
    # create_key: the rescue distinguishes a unique-constraint violation
    # (`{:error, :already_exists}`) from an outage — logic the helper
    # deliberately does not carry.
    "apps/cyfr/lib/arca/api_key_storage.ex" => 1,
    # create_webhook: same constraint-vs-outage branch as create_key.
    "apps/cyfr/lib/arca/webhook_storage.ex" => 1,
    # page/5: the rescue answers `{:error, {table, :database_error, cursor}}`
    # — resume state interpolated from scope, not a constant the helper
    # could return.
    "apps/cyfr/lib/sanctum/cipher/rotation.ex" => 1,
    # configure_database: a failed boot-time PRAGMA is tolerated at
    # `Logger.warning` and answers `:ok` — neither the helper's error-level
    # log nor a refusal fits a tuning step the server must boot past.
    "apps/cyfr/lib/cyfr/application.ex" => 1
  }

  test "inline db-errors rescues exist only at the enumerated exceptions" do
    found =
      for dir <- ["apps/cyfr/lib", "apps/opus/lib", "apps/locus/lib"],
          file <- Path.wildcard(Path.join([@root, dir, "**/*.ex"])),
          count = length(Regex.scan(@rescue_pattern, File.read!(file))),
          count > 0,
          into: %{} do
        {Path.relative_to(file, @root), count}
      end

    new_sites =
      for {file, count} <- found,
          count > Map.get(@allowed, file, 0),
          do: {file, count - Map.get(@allowed, file, 0)}

    assert new_sites == [],
           """
           Inline `rescue e in Arca.Repo.Errors.db_errors()` outside this
           test's allowlist:

           #{Enum.map_join(Enum.sort(new_sites), "\n", fn {f, n} -> "  #{f} (+#{n})" end)}

           A database outage at a storage entry point has one spelling:
           wrap the body in `Arca.Repo.Errors.with_db_rescue("Module.fun", fn -> ... end)`
           (or `with_db_rescue/3` with a call-site comment for a deliberate
           default-returner) instead of copying the rescue. Only a rescue the
           helper genuinely cannot express belongs in the allowlist above,
           with a comment saying why.
           """

    stale = for {file, count} <- @allowed, Map.get(found, file, 0) != count, do: file

    assert stale == [],
           "stale allowlist entries (inline site count changed — update the " <>
             "roster and its comments): #{inspect(Enum.sort(stale))}"
  end
end
