# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DbRescueCoverageTest do
  @moduledoc """
  Every row-plane entry point in `apps/arca/lib/arca` that touches the
  repo is rescued — or says why it is not.

  The complement of `Arca.DbRescueSeamTest`: that seam catches the WRONG
  rescue (an inline `rescue e in db_errors()` outside the allowlist); it
  structurally cannot catch a MISSING one. `Arca.CronSchedule` passed it
  with zero rescues across fifteen entry points, so a SQLite hiccup raised
  straight into the scheduler — which is exactly what this test would have
  refused.

  A function counts as covered when its body runs under `with_db_rescue`
  (or the local `rescuing_db` wrapper), carries its own `rescue`, or is
  tagged `# arca:db-raise-ok <why>` — for the sites where raising is the
  contract (a step inside a caller's `Repo.transaction/1` must raise to
  roll the transaction back, and a private helper is covered by the public
  entry that wraps it).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Same boundary fix as `Arca.UnscopedQuerySeamTest`: `exists?` and
  # `query!` cannot carry a trailing `\b`.
  @repo_call ~r/\b(?:Arca\.)?Repo\.(?:(?:all|one|update_all|delete_all|aggregate|get|get_by|insert|insert_all|update|delete|transaction|rollback)\b|exists\?|query!?)/
  @covered ~r/with_db_rescue|rescuing_db|^\s*rescue\b/m
  @tag_marker ~r/#\s*arca:db-raise-ok\s+\S/

  defp sources do
    [@root, "apps/arca/lib/arca", "**/*.ex"] |> Path.join() |> Prima.Test.SourceTree.files!()
  end

  # Same per-function segmentation as Arca.UnscopedQuerySeamTest: heads at
  # two-space `def`/`defp`, the contiguous comment lines above riding along.
  defp functions(lines) do
    starts = for {line, i} <- Enum.with_index(lines), line =~ ~r/^  defp? /, do: i

    bounds =
      Enum.zip(
        starts,
        Enum.map(Enum.drop(starts, 1), &(&1 - length(comments_above(lines, &1)))) ++
          [length(lines)]
      )

    for {from, to} <- bounds do
      preamble = comments_above(lines, from)
      body = Enum.slice(lines, from, max(to - from, 1))
      {from + 1, Enum.join(preamble ++ body, "\n")}
    end
  end

  defp comments_above(lines, index) do
    lines
    |> Enum.take(index)
    |> Enum.reverse()
    |> Enum.take_while(&(&1 =~ ~r/^\s*#/))
    |> Enum.reverse()
  end

  # Private helpers are covered by the public entry that wraps them in the
  # rescue — requiring the marker on every `defp` would just push the tag
  # inward. Only `def` heads are entry points.
  defp public?(body), do: body =~ ~r/^  def /m

  test "every public row-plane entry that touches the repo is rescued or says why" do
    offenders =
      for path <- sources(),
          source = Prima.Test.SourceTree.read(path),
          {line, body} <- functions(String.split(source, "\n")),
          public?(body),
          body =~ @repo_call,
          not (body =~ @covered),
          not (body =~ @tag_marker) do
        head = body |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^  def /)) |> String.trim()
        "#{Path.relative_to(path, @root)}:#{line}: #{head}"
      end

    assert offenders == [],
           """
           These public row-plane entries touch the repo with no rescue and
           no stated reason:

           #{Enum.map_join(Enum.sort(offenders), "\n", &"  #{&1}")}

           Wrap the body in `Arca.Repo.Errors.with_db_rescue/2` (the
           row-plane convention: a store that cannot answer says
           `{:error, :database_error}`, it does not raise into a LiveView
           or a scheduler). Where raising IS the contract — a transaction
           step, a boot-time read — put `# arca:db-raise-ok <why>` on the
           head so the decision is greppable.
           """
  end
end
