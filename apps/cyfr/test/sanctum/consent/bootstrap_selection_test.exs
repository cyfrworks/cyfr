# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BootstrapSelectionTest do
  @moduledoc """
  The shipped soul's baseline consent selects, on its edge to the shipped
  catalyst it runs on, that catalyst's default profile — so the key a
  person binds on the catalyst is what the assistant runs it with. A
  person's own formula is not machine-minted.
  A boot re-mints a bootstrap-only consent that lacks the
  selections its dependencies offer, or whose closure the seed moved,
  and leaves a person's consent and a person's closure alone.
  """

  use ExUnit.Case, async: false

  alias Arca.ConsentStorage
  alias Sanctum.Consent.{Bootstrap, Source}

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")
  @aqua "agent:local.aqua"
  @claude "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_selection_#{System.unique_integer([:positive])}")

    seed_dir = Path.join(test_dir, "seed")
    copy_bundle!(Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    prev_base = Application.get_env(:cyfr, :base_path)
    prev_seed = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(test_dir)
    end)

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Selection",
        slug: "selection-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: athanor.id, scope: :athanor)
    {:ok, _copied} = Arca.Overlay.materialize_shipped(ctx, "components")
    {:ok, _copied} = Arca.Overlay.materialize_shipped(ctx, "aqua")
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    {:ok, ctx: ctx}
  end

  defp head!(ctx, ref) do
    {:ok, [profile]} = Source.DB.profiles(ctx, ref)
    {:ok, row, refs} = ConsentStorage.get_head(ctx.athanor_id, profile.id)
    {profile, row, refs}
  end

  defp edge!(policy, from, to) do
    {:ok, blob} = Cyfr.Authority.Blob.parse(policy)
    {:ok, edge} = Cyfr.Authority.Blob.lookup_edge(blob, from, to, "")
    edge
  end

  test "the shipped soul selects its model's default profile", %{ctx: ctx} do
    {:ok, %{minted: minted, revised: []}} = Bootstrap.run(ctx)
    assert @aqua in minted and @claude in minted

    {claude, claude_head, claude_refs} = head!(ctx, @claude)
    assert claude.label == "default" and claude.kind == :owner
    assert claude_refs == []
    assert edge!(claude_head.resolved_policy, @claude, "@ingress") |> then(& &1.vault) == nil

    {_aqua, aqua_head, aqua_refs} = head!(ctx, @aqua)
    assert aqua_refs == []

    edge = edge!(aqua_head.resolved_policy, @aqua, @claude)
    assert edge.vault == %{via: %{label: "default", binding_digest: nil}, projection: nil}

    # A dependency without a credential need is not selected.
    assert edge!(aqua_head.resolved_policy, @aqua, "catalyst:local.files").vault == nil

    # Idempotent: nothing to mint or revise on the next boot.
    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
  end

  test "a person's own formula is not machine-minted", %{ctx: ctx} do
    shipped = [
      "components",
      "formulas",
      "local",
      "list-models",
      shipped_version("formulas", "list-models")
    ]

    mine = ["components", "formulas", "local", "mine", "0.1.0"]
    {:ok, manifest} = Arca.get_json(ctx, shipped ++ ["cyfr-manifest.json"])
    {:ok, wasm} = Arca.get(ctx, shipped ++ ["formula.wasm"])
    :ok = Arca.put(ctx, mine ++ ["formula.wasm"], wasm)

    :ok =
      Arca.put_json(ctx, mine ++ ["cyfr-manifest.json"], %{
        manifest
        | "name" => "mine",
          "version" => "0.1.0"
      })

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, mine)

    {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    refute "formula:local.mine" in minted
    assert {"formula:local.mine", :not_vouched} in skipped
    assert {:ok, []} = Source.DB.profiles(ctx, "formula:local.mine")
  end

  test "an edited shipped component is not re-minted", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_claude, first, _} = head!(ctx, @claude)
    version = shipped_version("catalysts", "claude")
    unit = ["components", "catalysts", "local", "claude", version]
    {:ok, manifest} = Arca.get_json(ctx, unit ++ ["cyfr-manifest.json"])

    :ok =
      Arca.put_json(
        ctx,
        unit ++ ["cyfr-manifest.json"],
        put_in(manifest, ["caps", "egress", "methods"], ["GET", "POST", "DELETE"])
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {@claude, :shape_moved} in skipped
    {_, still, _} = head!(ctx, @claude)
    assert still.revision == first.revision
  end

  test "a seed update re-mints a bootstrap-only consent; a person's consent or closure stays", %{
    ctx: ctx
  } do
    {:ok, _} = Bootstrap.run(ctx)
    {_aqua, first, _} = head!(ctx, @aqua)
    {_, list_first, _} = head!(ctx, "formula:local.list-models")
    old_digest = first.activation |> Jason.decode!() |> Map.fetch!(@claude)

    # A release retires the claude version this estate holds and ships a
    # new one. Until the estate takes the new version, its copy of the old
    # one is no longer a shipped path — but it is unchanged and the head
    # names it, so the selection stays and nothing is re-minted.
    seed_dir = Application.get_env(:cyfr, :seed_path)
    current = shipped_version("catalysts", "claude")
    ship_version!(seed_dir, "claude", current, "9.0.0")
    File.rm_rf!(Path.join([seed_dir, "components", "catalysts", "local", "claude", current]))

    assert {:ok, :own} =
             Arca.Overlay.unit_status(ctx, ["components", "catalysts", "local", "claude", current])

    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
    {_, kept, _} = head!(ctx, @aqua)
    assert kept.revision == first.revision
    assert %{via: %{label: "default"}} = edge!(kept.resolved_policy, @aqua, @claude).vault

    # The estate takes the new release: the assistant's closure moves, and
    # every node of it is the seed's own or unchanged since the head.
    {:ok, _copied} = Arca.Overlay.materialize_shipped(ctx, "components")
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)

    # The catalyst's own head re-mints too: its new release widened its
    # caps, and that closure is the seed's alone.
    # Every shipped agent whose closure holds claude moves with it; nothing
    # else does.
    {:ok, %{minted: [], revised: revised}} = Bootstrap.run(ctx)
    assert @claude in revised and @aqua in revised and "formula:local.list-models" in revised

    assert Enum.all?(
             revised -- [@claude, "formula:local.list-models"],
             &String.starts_with?(&1, "agent:")
           )

    {_, healed, _} = head!(ctx, @aqua)
    assert healed.revision == first.revision + 1
    assert healed.granted_via == "bootstrap"
    assert healed.shape_digest != first.shape_digest
    new_digest = healed.activation |> Jason.decode!() |> Map.fetch!(@claude)
    assert new_digest != old_digest
    # The selection rides into the re-mint.
    assert %{via: %{label: "default"}} = edge!(healed.resolved_policy, @aqua, @claude).vault
    {_, list_healed, _} = head!(ctx, "formula:local.list-models")
    assert list_healed.revision == list_first.revision + 1

    # Idempotent once re-minted.
    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)

    # A person's own claude release moves the closure again; that closure
    # is not the seed's, so the boot leaves the head where it is.
    own = ["components", "catalysts", "local", "claude", "9.1.0"]
    shipped = ["components", "catalysts", "local", "claude", "9.0.0"]
    {:ok, manifest} = Arca.get_json(ctx, shipped ++ ["cyfr-manifest.json"])
    {:ok, wasm} = Arca.get(ctx, shipped ++ ["catalyst.wasm"])
    :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], wasm)

    :ok =
      Arca.put_json(
        ctx,
        own ++ ["cyfr-manifest.json"],
        manifest
        |> Map.put("version", "9.1.0")
        |> put_in(["caps", "egress", "methods"], ["GET", "POST", "DELETE", "PUT"])
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, own)
    assert {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {@aqua, :shape_moved} in skipped
    {_, still, _} = head!(ctx, @aqua)
    assert still.revision == healed.revision
  end

  # A new shipped release of a catalyst in the test seed: the current
  # version's files under a new version directory, the manifest bumped and
  # its egress widened so the release digest moves as a real release does.
  defp ship_version!(seed_dir, name, from, to) do
    src = Path.join([seed_dir, "components", "catalysts", "local", name, from])
    dest = Path.join([seed_dir, "components", "catalysts", "local", name, to])
    File.mkdir_p!(dest)
    File.cp!(Path.join(src, "catalyst.wasm"), Path.join(dest, "catalyst.wasm"))

    manifest =
      src
      |> Path.join("cyfr-manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("version", to)
      |> put_in(["caps", "egress", "methods"], ["GET", "POST", "DELETE"])

    File.write!(Path.join(dest, "cyfr-manifest.json"), Jason.encode!(manifest))
  end

  defp shipped_version(plural, name) do
    [dir] = Path.wildcard(Path.join([@bundle, plural, "local", name, "*"]))
    Path.basename(dir)
  end

  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Cyfr.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      target = Path.join(dest, Path.relative_to(src, @bundle))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
