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
  # `query!` cannot carry a trailing `\b`. Ecto's raising forms (`get!`,
  # `insert!`, …) match through the `\b` before their `!`; `Arca.Repo`'s
  # own transactions and its transaction lock raise too, so they are listed.
  @repo_call ~r/\b(?:Arca\.)?Repo\.(?:(?:all|one|update_all|delete_all|aggregate|get|get_by|insert|insert_all|insert_or_update|update|delete|transaction|locking_transaction|read_transaction|transaction_lock|rollback)\b|exists\?|query!?)/
  @covered ~r/with_db_rescue|rescuing_db|^\s*rescue\b/m
  @tag_marker ~r/#\s*arca:db-raise-ok\s+\S/

  defp sources do
    [@root, "apps/arca/lib/arca", "**/*.ex"] |> Path.join() |> Prima.Test.SourceTree.files!()
  end

  # Same per-function segmentation as Arca.UnscopedQuerySeamTest: heads at
  # two-space `def`/`defp`, the contiguous comment lines above riding along.
  # A body ends at the next `@doc`, so the documentation of the function
  # after it, which may name Repo functions, is never read as its code.
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
      to = Enum.find((from + 1)..(to - 1)//1, to, &(Enum.at(lines, &1) =~ ~r/^  @doc\b/))
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

  # `sources` is `[{relative_path, source}]`, so a planted file is checked
  # exactly as a real one is.
  defp offenders(sources) do
    for {path, source} <- sources,
        {line, body} <- functions(String.split(source, "\n")),
        public?(body),
        body =~ @repo_call,
        not (body =~ @covered),
        not (body =~ @tag_marker) do
      head = body |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^  def /)) |> String.trim()
      "#{path}:#{line}: #{head}"
    end
  end

  test "every public row-plane entry that touches the repo is rescued or says why" do
    offenders =
      offenders(
        for path <- sources(),
            do: {Path.relative_to(path, @root), Prima.Test.SourceTree.read(path)}
      )

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

  test "a planted entry that opens Arca.Repo's own transaction or lock unrescued is refused, and the next function's doc is not its body" do
    planted = [
      {"apps/arca/lib/arca/planted.ex",
       ~S'''
       defmodule Arca.Planted do
         def a(fun), do: Arca.Repo.locking_transaction(fun)

         def b(fun), do: Repo.read_transaction(fun)

         def c, do: Arca.Repo.transaction_lock(1)

         def d(changeset), do: Repo.insert_or_update(changeset)

         def e(fun) do
           Arca.Repo.Errors.with_db_rescue("Arca.Planted.e", fn ->
             Arca.Repo.locking_transaction(fun)
           end)
         end

         # arca:db-raise-ok a step inside its caller's transaction
         def f, do: Arca.Repo.transaction_lock(2)

         def g, do: :ok

         @doc """
         Not one of these: it reads nothing through Arca.Repo.all/1 or
         Arca.Repo.locking_transaction/2.
         """
         def h, do: :ok
       end
       '''}
    ]

    assert offenders(planted) == [
             "apps/arca/lib/arca/planted.ex:2: def a(fun), do: Arca.Repo.locking_transaction(fun)",
             "apps/arca/lib/arca/planted.ex:4: def b(fun), do: Repo.read_transaction(fun)",
             "apps/arca/lib/arca/planted.ex:6: def c, do: Arca.Repo.transaction_lock(1)",
             "apps/arca/lib/arca/planted.ex:8: def d(changeset), do: Repo.insert_or_update(changeset)"
           ]
  end
end
