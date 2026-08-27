# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProvenanceTest do
  @moduledoc """
  Provenance is derived from the tree, never stored: bundled vs
  bundled-modified vs user vs remote — and the delete/reset semantics that
  hang off it. Includes the resurrection-bug regression: deleting a
  bundled component must refuse (row intact, bytes untouched), never
  report "deleted" and quietly come back at the next scan.
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
    seed = Path.join(base, "seed")

    bundle_version = Path.join([seed, "components", "reagents", "local", "bundled-tool", "1.0.0"])
    File.mkdir_p!(bundle_version)

    File.write!(
      Path.join(bundle_version, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"})
    )

    File.write!(Path.join(bundle_version, "reagent.wasm"), @valid_wasm)

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    {:ok, bundled} = Registry.register_from_arca(ctx, @bundled_dir)

    {:ok, ctx: ctx, bundled: bundled}
  end

  test "of/2 tells the four classes apart", %{ctx: ctx, bundled: bundled} do
    assert Provenance.of(ctx, bundled) == {:ok, :bundled}

    # An edit copy-on-writes the unit — same row, different provenance.
    :ok = Arca.put(ctx, @bundled_dir ++ ["notes.txt"], "edited")
    assert Provenance.of(ctx, bundled) == {:ok, :bundled_modified}

    # The athanor's own component: tenant bytes, no seed counterpart.
    own_dir = ["components", "reagents", "local", "own-tool", "0.1.0"]
    own_local = Arca.Adapters.Local.build_path(ctx, own_dir)
    File.mkdir_p!(own_local)

    File.write!(
      Path.join(own_local, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "0.1.0"})
    )

    File.write!(Path.join(own_local, "reagent.wasm"), @valid_wasm)
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
    assert provenance_map[{"bundled-tool", "1.0.0", "local"}] == :bundled_modified
    assert provenance_map[{"own-tool", "0.1.0", "local"}] == :user
    assert provenance_map[{"remote-tool", "1.0.0", "local"}] == :remote
  end

  test "of_status/1 covers every overlay state; label/1 is closed" do
    assert Provenance.of_status(:seed) == :bundled
    assert Provenance.of_status(:materialized) == :bundled_modified
    assert Provenance.of_status(:own) == :user
    assert Provenance.of_status(:absent) == :user

    for provenance <- [:bundled, :bundled_modified, :user, :remote] do
      assert Provenance.label(provenance) == Atom.to_string(provenance)
    end

    assert_raise FunctionClauseError, fn -> Provenance.label(:shipped) end
    assert_raise FunctionClauseError, fn -> Provenance.of_status(:hidden) end
  end

  test "shipped_versions/2 reads the release catalog from the seed", %{ctx: _ctx} do
    assert Provenance.shipped_versions("reagent", "bundled-tool") == {:ok, ["1.0.0"]}
    assert Provenance.shipped_versions("reagent", "nope") == {:ok, []}
  end

  test "overview/1 answers the whole athanor with catalog and superseded flags", %{ctx: ctx} do
    # The next release ships 1.1.0 beside the registered 1.0.0.
    seed_v2 =
      Path.join([
        Application.fetch_env!(:cyfr, :seed_path),
        "components/reagents/local/bundled-tool/1.1.0"
      ])

    File.mkdir_p!(seed_v2)

    File.write!(
      Path.join(seed_v2, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.1.0"})
    )

    File.write!(Path.join(seed_v2, "reagent.wasm"), @valid_wasm)

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

    # Materialize without editing shipped content — still pristine.
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

    assert {:error, :bundled_modified} = Registry.delete(ctx, "bundled-tool", "1.0.0")
    assert {:ok, _} = Registry.get(ctx, "bundled-tool", "1.0.0")
  end

  test "reset/4 reverts an edited copy to shipped and refuses everything else", %{
    ctx: ctx,
    bundled: bundled
  } do
    assert {:ok, :already_pristine} = Registry.reset(ctx, "bundled-tool", "1.0.0")

    :ok = Arca.put(ctx, @bundled_dir ++ ["reagent.wasm"], @valid_wasm <> <<0>>)
    assert Provenance.of(ctx, bundled) == {:ok, :bundled_modified}

    assert {:ok, :reset} = Registry.reset(ctx, "bundled-tool", "1.0.0")
    assert Provenance.of(ctx, bundled) == {:ok, :bundled}
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

  test "a user component a LATER release also ships stays the user's", %{ctx: ctx} do
    # The athanor scaffolds mine-first 1.0.0 while no release ships it.
    own_dir = ["components", "reagents", "local", "mine-first", "1.0.0"]
    :ok = Arca.put(ctx, own_dir ++ ["reagent.wasm"], @valid_wasm)

    :ok =
      Arca.put(
        ctx,
        own_dir ++ ["cyfr-manifest.json"],
        Jason.encode!(%{"type" => "reagent", "version" => "1.0.0"})
      )

    {:ok, own} = Registry.register_from_arca(ctx, own_dir)
    assert Provenance.of(ctx, own) == {:ok, :user}

    # A later release ships the very same name and version.
    shipped_wasm = @valid_wasm <> <<1>>

    seed_dir =
      Path.join([
        Application.fetch_env!(:cyfr, :seed_path),
        "components/reagents/local/mine-first/1.0.0"
      ])

    File.mkdir_p!(seed_dir)

    File.write!(
      Path.join(seed_dir, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"})
    )

    File.write!(Path.join(seed_dir, "reagent.wasm"), shipped_wasm)

    # Still the user's work: reset refuses to wipe it, delete is allowed —
    # and only then does the shipped unit show through.
    assert Provenance.of(ctx, own) == {:ok, :user}
    assert {:error, :not_bundled} = Registry.reset(ctx, "mine-first", "1.0.0")

    assert {:ok, _} = Registry.delete(ctx, "mine-first", "1.0.0")
    assert {:ok, ^shipped_wasm} = Arca.get(ctx, own_dir ++ ["reagent.wasm"])
  end

  test "status/2 answers provenance, drift and shadowing in one probe", %{
    ctx: ctx,
    bundled: bundled
  } do
    assert {:ok, %{provenance: :bundled, drift: :pristine, shadows_shipped: false}} =
             Provenance.status(ctx, bundled)

    :ok = Arca.put(ctx, @bundled_dir ++ ["reagent.wasm"], @valid_wasm <> <<0>>)

    assert {:ok,
            %{
              provenance: :bundled_modified,
              drift: {:modified, %{changed: [["reagent.wasm"]]}},
              shadows_shipped: false
            }} = Provenance.status(ctx, bundled)

    # drift/2 is a thin reading of the same answer.
    assert {:ok, {:modified, _}} = Provenance.drift(ctx, bundled)

    {:ok, remote} =
      Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "remote-tool",
        version: "1.0.0",
        type: "reagent"
      })

    assert {:ok, %{provenance: :remote, drift: nil, shadows_shipped: false}} =
             Provenance.status(ctx, remote)
  end

  test "the athanor's own unit over a shipped counterpart reads shadows_shipped", %{ctx: ctx} do
    own_dir = ["components", "reagents", "local", "mine-first", "1.0.0"]
    :ok = Arca.put(ctx, own_dir ++ ["reagent.wasm"], @valid_wasm)

    :ok =
      Arca.put(
        ctx,
        own_dir ++ ["cyfr-manifest.json"],
        Jason.encode!(%{"type" => "reagent", "version" => "1.0.0"})
      )

    {:ok, own} = Registry.register_from_arca(ctx, own_dir)
    assert {:ok, %{provenance: :user, shadows_shipped: false}} = Provenance.status(ctx, own)

    seed_dir =
      Path.join([
        Application.fetch_env!(:cyfr, :seed_path),
        "components/reagents/local/mine-first/1.0.0"
      ])

    File.mkdir_p!(seed_dir)

    File.write!(
      Path.join(seed_dir, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.0.0"})
    )

    assert {:ok, %{provenance: :user, drift: nil, shadows_shipped: true}} =
             Provenance.status(ctx, own)

    {:ok, [entry]} = Provenance.annotate(ctx, [own])
    assert entry.shadows_shipped
    assert entry.provenance == :user
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
    # An already-decoded map answers; malformed JSON that merely CONTAINS
    # the substring answers nil (the old substring guard's false-positive
    # class); a non-string value answers nil.
    map_row = %{manifest: %{"forked_from" => "reagent:acme.up:1.0.0"}, name: "x", version: "1"}
    assert %{forked_from: "reagent:acme.up:1.0.0"} = lineage(ctx, map_row)

    broken_row = %{manifest: ~s({"forked_from": broken json), name: "x", version: "1"}
    assert lineage(ctx, broken_row) == nil

    non_string = %{manifest: %{"forked_from" => 42}, name: "x", version: "1"}
    assert lineage(ctx, non_string) == nil
  end

  defp lineage(ctx, row), do: Provenance.upstream_status(ctx, row)

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
