# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.RoomRefusalTest do
  @moduledoc """
  A start refused for room names the person's own holdings by their rows'
  names, read under the person's own scope first (`Opus.Programs.full/3`),
  and nothing else of anyone: two people each hold a program, and each
  one's refusal names only their own; a subject of the other's row, were
  it ever handed, is counted by its kind and never named; a row the person
  deleted is counted and not named; what anyone else holds is only the one
  sum the keeper gave.
  """
  use ExUnit.Case, async: false

  alias Opus.Programs

  @mib 1024 * 1024

  setup do
    Cyfr.Test.Sandbox.setup!()
    {:ok, ana: person!("ana"), ben: person!("ben")}
  end

  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "local|local|room-#{name}-#{n}",
        provider: "local",
        name: "#{name} #{n}"
      })

    own = Sanctum.Test.People.athanor!(user)
    ctx = %{Sanctum.TestContext.local(:prism) | user_id: user.id, athanor_id: own.id}
    %{ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  defp row!(%{actor: actor}, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "mcp",
        url: nil,
        config_json: Jason.encode!(%{"command" => "true", "timeout_ms" => 5_000})
      })

    row
  end

  defp held(mine, others),
    do: %{need: 384 * @mib, free: 0, mine: mine, others_bytes: others}

  defp program(subject, mib), do: %{kind: "program", subject: subject, bytes: mib * @mib}

  defp sentence(person, what, held),
    do: Prima.Refusal.message(Programs.full(person.actor, what, held))

  test "each of two people's refusals names only their own programs, the other's in the sum",
       %{ana: ana, ben: ben} do
    claude = row!(ana, "claude-code")
    codex = row!(ben, "codex")

    # What the keeper gives each: their own holdings with subjects, the
    # other's within others_bytes.
    for {person, own, other, mine_mib, others_mib, name} <- [
          {ana, claude, codex, 700, 300, "claude-code"},
          {ben, codex, claude, 300, 700, "codex"}
        ] do
      said = sentence(person, "Aqua", held([program(own.id, mine_mib)], others_mib * @mib))

      assert said ==
               "Aqua could not start: this CYFR has not enough memory free. Of yours, #{name} " <>
                 "uses #{Prima.Bytes.format(mine_mib * @mib)}. Others use " <>
                 "#{Prima.Bytes.format(others_mib * @mib)}. Stop one on the Programs page, or wait."

      refute said =~ other.name
      refute said =~ own.id
    end
  end

  test "a subject of a row the person cannot read is counted by its kind, never named",
       %{ana: ana, ben: ben} do
    mine = row!(ana, "claude-code")
    theirs = row!(ben, "codex")
    gone = row!(ana, "gemini")
    {:ok, _deleted} = Arca.McpServerStorage.delete(ana.actor, gone.name)

    said =
      sentence(
        ana,
        "Aqua",
        held([program(mine.id, 500), program(theirs.id, 200), program(gone.id, 100)], 0)
      )

    assert said ==
             "Aqua could not start: this CYFR has not enough memory free. Of yours, claude-code " <>
               "uses 500.0 MB and 2 programs use 300.0 MB. Stop one on the Programs page, or wait."

    refute said =~ "codex"
    refute said =~ "gemini"
  end

  test "names are read under the person's own scope first, and none with nothing to name",
       %{ana: ana, ben: ben} do
    row = row!(ana, "claude-code")

    assert {:program_full, "Aqua", _held, %{} = names} =
             Programs.full(ana.actor, "Aqua", held([program(row.id, 400)], 0))

    assert names == %{row.id => "claude-code"}

    # Under another person's scope the same subject is no name.
    assert {:program_full, "Aqua", _held, names} =
             Programs.full(ben.actor, "Aqua", held([program(row.id, 400)], 0))

    assert names == %{}

    assert {:program_full, "Aqua", nil, names} = Programs.full(ana.actor, "Aqua", nil)
    assert names == %{}

    assert Prima.Refusal.message(Programs.full(ana.actor, "Aqua", nil)) ==
             "Aqua could not start: no more programs, or no more of this program's sessions, " <>
               "may run on this CYFR at once. Stop one on the Programs page, or wait."
  end
end
