# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RevisionStoreReservedTest do
  @moduledoc """
  A seeded root's staging area, `{root}/.staging/`, holds every unit's
  revisions: units are served from there. A plain write, edit or delete
  of a path in it, through the athanor's files (`Arca.Files`) or the
  storage facade, is refused `{:reserved_path, path}` and moves no byte:
  the committed units stay readable and their rows keep naming bytes that
  exist. Only the internal-write scope — a commit, a repair, the
  collector — writes and deletes there.
  """

  use ExUnit.Case, async: false

  alias Arca.Files

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @mine "---\ntitle: Mine\n---\n\nmine\n"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "revision_store_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")

    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, seed)

    roles = Path.join([seed, "aqua", "roles"])
    File.mkdir_p!(roles)
    File.write!(Path.join([seed, "aqua", "aqua.md"]), "---\ntitle: A\n---\n\nsoul\n")
    File.write!(Path.join(roles, "scribe.md"), "---\ntitle: Scribe\n---\n\nscribe\n")

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    actor = Sanctum.Context.actor(ctx)
    :ok = Arca.ensure_roots(actor)
    {:ok, ctx: ctx, actor: actor}
  end

  # The own role's committed revision object, as a path in the staging area.
  defp own_role!(actor) do
    assert {:ok, _} = Files.write(actor, "aqua/roles/mine.md", @mine)

    assert {:ok, %{entries: [%{name: revision}]}} =
             Files.list(actor, "aqua/.staging/roles/mine.md")

    revision
  end

  defp assert_own_role_intact(actor) do
    assert {:ok, %{content: @mine}} = Files.read(actor, "aqua/roles/mine.md")
    assert {:ok, :own} = Arca.Overlay.unit_status(actor, ["aqua", "roles", "mine.md"])
    assert {:ok, @mine} = Arca.get(actor, ["aqua", "roles", "mine.md"])
  end

  describe "a delete in the revision store is refused" do
    test "the whole aqua staging area, through the athanor's files", %{actor: actor} do
      own_role!(actor)

      # Listing never shows the area; naming it is the only way to reach it.
      assert {:ok, %{tier: :shaped, entries: entries}} = Files.list(actor, "aqua")
      refute Enum.any?(entries, &(&1.name == ".staging"))

      assert {:error, {:reserved_path, ["aqua", ".staging"]} = reason} =
               Files.delete(actor, "aqua/.staging")

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               Prima.Refusal.classify(reason)

      assert message ==
               "This folder holds the server's stored unit revisions and only the server " <>
                 "changes it — edit or remove a unit at its own path, one unit at a time"

      assert_own_role_intact(actor)
    end

    test "the whole components staging area, through the athanor's files",
         %{ctx: ctx, actor: actor} do
      unit = ["components", "reagents", "local", "mine", "0.1.0"]

      Arca.Test.UnitFixtures.lay_unit!(ctx, unit, [
        {"reagent.wasm", @valid_wasm},
        {"cyfr-manifest.json", ~s({"type":"reagent","version":"0.1.0"})}
      ])

      assert {:ok, :own} = Arca.Overlay.unit_status(actor, unit)

      assert {:error, {:reserved_path, ["components", ".staging"]}} =
               Files.delete(actor, "components/.staging")

      assert {:ok, :own} = Arca.Overlay.unit_status(actor, unit)
      assert {:ok, _} = Arca.get(actor, unit ++ ["cyfr-manifest.json"])
      assert {:ok, @valid_wasm} = Arca.get(actor, unit ++ ["reagent.wasm"])
    end

    test "one committed object under a revision prefix, through the files and the facade",
         %{actor: actor} do
      revision = own_role!(actor)
      object = ["aqua", ".staging", "roles", "mine.md", revision, "mine.md"]

      assert {:error, {:reserved_path, ^object}} =
               Files.delete(actor, Enum.join(object, "/"))

      assert {:error, {:reserved_path, ^object}} = Arca.delete(actor, object)
      prefix = Enum.drop(object, -1)
      assert {:error, {:reserved_path, ^prefix}} = Arca.delete_tree(actor, prefix)

      assert {:error, {:reserved_path, ["aqua", ".staging"]}} =
               Arca.delete_tree(actor, ["aqua", ".staging"])

      # Refused for what it is, not answered by what happens to be there.
      assert {:error, {:reserved_path, ["aqua", ".staging", "roles", "none.md"]}} =
               Files.delete(actor, "aqua/.staging/roles/none.md")

      assert_own_role_intact(actor)
    end
  end

  describe "a write or an edit in the revision store is refused" do
    test "a write through the athanor's files and the facade", %{actor: actor} do
      revision = own_role!(actor)
      object = ["aqua", ".staging", "roles", "mine.md", revision, "mine.md"]
      planted = ["aqua", ".staging", "roles", "mine.md", "rev_planted", "mine.md"]

      assert {:error, {:reserved_path, ^object}} =
               Files.write(actor, Enum.join(object, "/"), "overwritten")

      assert {:error, {:reserved_path, ^planted}} =
               Files.write(actor, Enum.join(planted, "/"), "planted")

      assert {:error, {:reserved_path, ^object}} = Arca.put(actor, object, "overwritten")
      assert {:error, {:reserved_path, ^planted}} = Arca.put(actor, planted, "planted")

      assert {:error, {:reserved_path, ^object}} =
               Arca.put_if_none_match(actor, object, "overwritten")

      assert {:error, {:reserved_path, ["components", ".staging"]}} =
               Arca.ensure_dir(actor, ["components", ".staging"])

      assert {:error, :not_found} = Arca.get(actor, planted)
      assert_own_role_intact(actor)
    end

    test "an edit through the athanor's files and the facade", %{actor: actor} do
      revision = own_role!(actor)
      object = ["aqua", ".staging", "roles", "mine.md", revision, "mine.md"]

      assert {:error, {:reserved_path, ^object}} =
               Files.update(actor, Enum.join(object, "/"), fn text -> {:ok, text <> "edited"} end)

      assert {:error, {:reserved_path, ^object}} = Arca.append(actor, object, "appended")

      assert {:ok, _bytes, precondition} = Arca.get_for_update(actor, object)

      assert {:error, {:reserved_path, ^object}} =
               Arca.put_if_match(actor, object, "edited", precondition)

      prefix = Enum.drop(object, -1)

      assert {:error, {:reserved_path, ^prefix}} =
               Arca.replace_tree(actor, prefix, [{["mine.md"], "swapped"}], cap: :exempt)

      assert_own_role_intact(actor)
    end
  end

  test "the internal-write scope still writes and deletes in the revision store",
       %{actor: actor} do
    own_role!(actor)
    scratch = ["aqua", ".staging", "roles", "scratch.md", "rev_scratch", "scratch.md"]

    Arca.Overlay.with_internal_writes(fn ->
      assert :ok = Arca.put(actor, scratch, "scratch", cap: :exempt)
      assert {:ok, "scratch"} = Arca.get(actor, scratch)
      assert :ok = Arca.delete_tree(actor, Enum.drop(scratch, -2))
    end)

    assert {:error, :not_found} = Arca.get(actor, scratch)
    assert_own_role_intact(actor)
  end
end
