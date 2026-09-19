# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProvenanceTest do
  @moduledoc """
  Checks tree-derived provenance and its delete/reset behavior: a unit at
  a path the server ships is a shipped copy whatever its bytes, restored
  by reset and never deleted; an edit shows as drift.
  """

  use ExUnit.Case, async: false

  alias Compendium.Provenance
  alias Compendium.Registry

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @bundled_dir ["components", "reagents", "local", "bundled-tool", "1.0.0"]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    base = Path.join(System.tmp_dir!(), "provenance_#{System.unique_integer([:positive])}")

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, Path.join(base, "seed"))

    Arca.Test.UnitFixtures.seed_component!("reagent", "local", "bundled-tool", "1.0.0",
      manifest: %{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"},
      wasm: @valid_wasm
    )

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Arca.Overlay.pull_shipped(ctx, @bundled_dir)
    {:ok, bundled} = Registry.register_from_arca(ctx, @bundled_dir)

    {:ok, ctx: ctx, bundled: bundled}
  end

  test "of/2 tells the three classes apart", %{ctx: ctx, bundled: bundled} do
    assert Provenance.of(ctx, bundled) == {:ok, :bundled}

    # An edit does not change whose unit it is.
    :ok = Arca.put(ctx, @bundled_dir ++ ["notes.txt"], "edited")
    assert Provenance.of(ctx, bundled) == {:ok, :bundled}

    # The athanor's own component: tenant bytes, no seed counterpart.
    own_dir = ["components", "reagents", "local", "own-tool", "0.1.0"]

    Arca.Test.UnitFixtures.tenant_component!(ctx, "reagent", "local", "own-tool", "0.1.0",
      manifest: %{"type" => "reagent", "version" => "0.1.0"},
      wasm: @valid_wasm
    )

    {:ok, own} = Registry.register_from_arca(ctx, own_dir)
    assert Provenance.of(ctx, own) == {:ok, :user}

    # A published/pulled component is remote whatever the tree says.
    {:ok, remote} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "remote-tool",
        version: "1.0.0",
        type: "reagent"
      })

    assert Provenance.of(ctx, remote) == {:ok, :remote}

    # The batch map agrees with the one-row classification.
    {:ok, provenance_map} = Provenance.map(ctx)
    assert provenance_map[{"bundled-tool", "1.0.0", "local"}] == :bundled
    assert provenance_map[{"own-tool", "0.1.0", "local"}] == :user
    assert provenance_map[{"remote-tool", "1.0.0", "local"}] == :remote
  end

  test "of_status/1 covers every overlay state; label/1 is closed" do
    assert Provenance.of_status(:available) == :bundled
    assert Provenance.of_status(:shipped) == :bundled
    assert Provenance.of_status(:own) == :user
    assert Provenance.of_status(:absent) == :user

    for provenance <- [:bundled, :bundled_modified, :user, :remote] do
      assert Provenance.label(provenance) == Atom.to_string(provenance)
    end

    # Each function is closed over its own vocabulary: a word from the
    # other's, or from none, raises rather than minting a label or a
    # provenance. (A literal call the compiler refuses at the call site;
    # what these guard is a word that reaches them at runtime.)
    for {closed, word} <- [{&Provenance.label/1, :shipped}, {&Provenance.of_status/1, :hidden}] do
      assert_raise FunctionClauseError, fn -> closed.(word) end
    end
  end

  test "shipped_versions/2 reads the release catalog from the seed", %{ctx: _ctx} do
    assert Provenance.shipped_versions("reagent", "bundled-tool") == {:ok, ["1.0.0"]}
    assert Provenance.shipped_versions("reagent", "nope") == {:ok, []}
  end

  test "overview/1 answers the whole athanor with catalog and superseded flags", %{ctx: ctx} do
    # The next release ships 1.1.0 beside the registered 1.0.0.
    Arca.Test.UnitFixtures.seed_component!("reagent", "local", "bundled-tool", "1.1.0",
      manifest: %{"type" => "reagent", "version" => "1.1.0"},
      wasm: @valid_wasm
    )

    {:ok, _} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "remote-tool",
        version: "1.0.0",
        type: "reagent"
      })

    {:ok, overview} = Provenance.overview(ctx)

    bundled_entry = Enum.find(overview, &(&1.component.name == "bundled-tool"))
    assert bundled_entry.provenance == :bundled
    assert bundled_entry.shipped_versions == ["1.1.0", "1.0.0"]
    assert bundled_entry.superseded

    remote_entry = Enum.find(overview, &(&1.component.name == "remote-tool"))
    assert remote_entry.provenance == :remote
    assert remote_entry.shipped_versions == []
    refute remote_entry.superseded
  end

  test "drift/2 answers pristine and modified honestly", %{ctx: ctx, bundled: bundled} do
    assert {:ok, :pristine} = Provenance.drift(ctx, bundled)

    # An edit that leaves the shipped content as it was is still pristine
    # by bytes — the diff decides.
    :ok = Arca.put(ctx, @bundled_dir ++ ["notes.txt"], "x")
    :ok = Arca.delete(ctx, @bundled_dir ++ ["notes.txt"])
    assert {:ok, :pristine} = Provenance.drift(ctx, bundled)

    :ok = Arca.put(ctx, @bundled_dir ++ ["reagent.wasm"], @valid_wasm <> <<0>>)

    assert {:ok, {:modified, %{changed: [["reagent.wasm"]]}}} =
             Provenance.drift(ctx, bundled)
  end

  test "deleting a bundled component refuses — the resurrection bug stays dead", %{
    ctx: ctx,
    bundled: bundled
  } do
    assert {:error, :bundled} = Registry.delete(ctx, "bundled-tool", "1.0.0")

    # Row intact, bytes still visible — nothing half-deleted.
    assert {:ok, _} = Registry.get(ctx, "bundled-tool", "1.0.0")
    assert Arca.exists?(ctx, @bundled_dir ++ ["reagent.wasm"])

    # And the next scan registers nothing new: there is nothing to resurrect.
    assert {:ok, %{registered: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    assert Provenance.of(ctx, bundled) == {:ok, :bundled}
  end

  test "deleting an edited bundled copy refuses and points at reset", %{ctx: ctx} do
    :ok = Arca.put(ctx, @bundled_dir ++ ["notes.txt"], "edited")

    assert {:error, :bundled} = Registry.delete(ctx, "bundled-tool", "1.0.0")
    assert {:ok, _} = Registry.get(ctx, "bundled-tool", "1.0.0")
  end

  test "reset/4 restores a bundled copy to shipped and refuses everything else", %{
    ctx: ctx,
    bundled: bundled
  } do
    # An unedited copy resets to itself.
    assert {:ok, :reset} = Registry.reset(ctx, "bundled-tool", "1.0.0")

    :ok = Arca.put(ctx, @bundled_dir ++ ["reagent.wasm"], @valid_wasm <> <<0>>)
    assert {:ok, %{provenance: :bundled_modified}} = Provenance.status(ctx, bundled)

    assert {:ok, :reset} = Registry.reset(ctx, "bundled-tool", "1.0.0")
    assert {:ok, %{provenance: :bundled, drift: :pristine}} = Provenance.status(ctx, bundled)
    assert {:ok, @valid_wasm} = Arca.get(ctx, @bundled_dir ++ ["reagent.wasm"])

    # The row survived the revert and matches the pristine bytes again.
    assert {:ok, row} = Registry.get(ctx, "bundled-tool", "1.0.0")
    assert row.source == "filesystem"

    # The athanor's own component has nothing shipped to revert to.
    {:ok, _} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "remote-tool",
        version: "1.0.0",
        type: "reagent"
      })

    assert {:error, :not_bundled} = Registry.reset(ctx, "remote-tool", "1.0.0")
  end

  test "a user component at a path a LATER release ships becomes the bundled copy", %{ctx: ctx} do
    # The athanor scaffolds mine-first 1.0.0 while no release ships it.
    own_dir = ["components", "reagents", "local", "mine-first", "1.0.0"]
    # Landed the one way a unit lands: its row publishes it, so it is a
    # complete copy once a release ships the same path.
    {:ok, _written} =
      Arca.Overlay.commit_unit(
        ctx,
        own_dir,
        {:files,
         [
           {["reagent.wasm"], @valid_wasm},
           {["cyfr-manifest.json"], Jason.encode!(%{"type" => "reagent", "version" => "1.0.0"})}
         ]},
        cap: :exempt
      )

    {:ok, own} = Registry.register_from_arca(ctx, own_dir)
    assert Provenance.of(ctx, own) == {:ok, :user}

    # A later release ships the very same name and version.
    Arca.Test.UnitFixtures.seed_component!("reagent", "local", "mine-first", "1.0.0",
      manifest: %{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"},
      wasm: @valid_wasm
    )

    # Bundled now, and edited by its bytes: delete refuses, reset puts the
    # shipped bytes there.
    assert Provenance.of(ctx, own) == {:ok, :bundled}
    assert {:ok, %{provenance: :bundled_modified}} = Provenance.status(ctx, own)
    assert {:error, :bundled} = Registry.delete(ctx, "mine-first", "1.0.0")

    assert {:ok, :reset} = Registry.reset(ctx, "mine-first", "1.0.0")
    assert {:ok, manifest} = Arca.get(ctx, own_dir ++ ["cyfr-manifest.json"])
    assert %{"description" => "shipped"} = Jason.decode!(manifest)
    assert {:ok, %{provenance: :bundled, drift: :pristine}} = Provenance.status(ctx, own)
  end

  test "status/2 answers provenance and drift in one probe", %{ctx: ctx, bundled: bundled} do
    assert {:ok, %{provenance: :bundled, drift: :pristine}} = Provenance.status(ctx, bundled)

    :ok = Arca.put(ctx, @bundled_dir ++ ["reagent.wasm"], @valid_wasm <> <<0>>)

    assert {:ok,
            %{
              provenance: :bundled_modified,
              drift: {:modified, %{changed: [["reagent.wasm"]]}}
            }} = Provenance.status(ctx, bundled)

    # drift/2 is a thin reading of the same answer.
    assert {:ok, {:modified, _}} = Provenance.drift(ctx, bundled)

    {:ok, remote} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "remote-tool",
        version: "1.0.0",
        type: "reagent"
      })

    assert {:ok, %{provenance: :remote, drift: nil}} = Provenance.status(ctx, remote)
    assert {:error, :not_bundled} = Provenance.drift(ctx, remote)
  end

  test "annotate/2 carries fork lineage, and malformed lineage never raises", %{ctx: ctx} do
    # The upstream line, two versions of it — the fork was cut from 1.0.0.
    for version <- ["1.0.0", "1.1.0"] do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "base",
          version: version,
          type: "reagent",
          publisher: "acme"
        })
    end

    {:ok, fork} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "my-fork",
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"forked_from" => "reagent:acme.base:1.0.0"})
      })

    assert %{
             forked_from: "reagent:acme.base:1.0.0",
             upstream_versions: ["1.1.0", "1.0.0"],
             upstream_superseded: true
           } = Provenance.upstream_status(ctx, fork)

    {:ok, [entry]} = Provenance.annotate(ctx, [fork])
    assert entry.forked_from == "reagent:acme.base:1.0.0"
    assert entry.upstream_superseded

    # A fork cut from the newest known upstream is not superseded.
    {:ok, current_fork} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "current-fork",
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"forked_from" => "reagent:acme.base:1.1.0"})
      })

    {:ok, [current]} = Provenance.annotate(ctx, [current_fork])
    refute current.upstream_superseded

    # Malformed lineage answers nothing, never a raise.
    {:ok, weird} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "weird-fork",
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"forked_from" => "not a ref at all"})
      })

    assert Provenance.upstream_status(ctx, weird) == nil
    {:ok, [w]} = Provenance.annotate(ctx, [weird])
    assert w.forked_from == nil
    refute w.upstream_superseded
  end

  test "the fork stamp reads through the manifest decode, whatever the shape", %{ctx: ctx} do
    # Decode provenance from valid maps; malformed JSON and non-string values return nil.
    map_row = %{manifest: %{"forked_from" => "reagent:acme.up:1.0.0"}, name: "x", version: "1"}
    assert %{forked_from: "reagent:acme.up:1.0.0"} = lineage(ctx, map_row)

    broken_row = %{manifest: ~s({"forked_from": broken json), name: "x", version: "1"}
    assert lineage(ctx, broken_row) == nil

    non_string = %{manifest: %{"forked_from" => 42}, name: "x", version: "1"}
    assert lineage(ctx, non_string) == nil
  end

  defp lineage(ctx, row), do: Provenance.upstream_status(ctx, row)

  test "shipped_release_digest/1 matches the registered digest of an unedited seed unit", %{
    bundled: bundled
  } do
    assert {:ok, bundled.release_digest} == Provenance.shipped_release_digest(bundled)
  end

  test "shipped_release_digest/1 stays the seed's digest after a tenant edit", %{
    ctx: ctx,
    bundled: bundled
  } do
    {:ok, seed_digest} = Provenance.shipped_release_digest(bundled)
    {:ok, manifest} = Arca.get_json(ctx, @bundled_dir ++ ["cyfr-manifest.json"])

    :ok =
      Arca.put_json(
        ctx,
        @bundled_dir ++ ["cyfr-manifest.json"],
        Map.put(manifest, "caps", %{"tools" => ["component.list"]})
      )

    {:ok, _} = Registry.register_from_arca(ctx, @bundled_dir)
    {:ok, edited} = Registry.get(ctx, "bundled-tool", "1.0.0")
    refute edited.release_digest == seed_digest
    assert {:ok, ^seed_digest} = Provenance.shipped_release_digest(edited)
  end

  test "shipped_release_digest/1 is :not_shipped for a tenant-only unit", %{ctx: ctx} do
    own_dir = ["components", "reagents", "local", "own-digest", "0.1.0"]

    Arca.Test.UnitFixtures.tenant_component!(ctx, "reagent", "local", "own-digest", "0.1.0",
      manifest: %{"type" => "reagent", "version" => "0.1.0"},
      wasm: @valid_wasm
    )

    {:ok, own} = Registry.register_from_arca(ctx, own_dir)
    assert {:error, :not_shipped} = Provenance.shipped_release_digest(own)

    assert {:error, :not_wasm_unit} =
             Provenance.shipped_release_digest(%{component_type: "tincture"})
  end

  test "deleting a user component still deletes outright", %{ctx: ctx} do
    {:ok, _} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "gone-tool",
        version: "1.0.0",
        type: "reagent"
      })

    assert {:ok, _} = Registry.delete(ctx, "gone-tool", "1.0.0")
    assert {:error, :not_found} = Registry.get(ctx, "gone-tool", "1.0.0")

    refute Arca.exists?(ctx, [
             "components",
             "reagents",
             "local",
             "gone-tool",
             "1.0.0",
             "reagent.wasm"
           ])
  end
end
