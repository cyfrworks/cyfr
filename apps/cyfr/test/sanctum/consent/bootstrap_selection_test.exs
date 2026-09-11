# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BootstrapSelectionTest do
  @moduledoc """
  A shipped formula's baseline consent selects, on its edge to each
  shipped catalyst that needs a credential, that catalyst's default
  profile — so the key a person binds on the catalyst is what the
  assistant runs it with. A person's own formula selects nothing at
  bootstrap, and a boot revises a bootstrap-only consent that lacks the
  selections its dependencies offer, and nothing else.
  """

  use ExUnit.Case, async: false

  alias Arca.ConsentStorage
  alias Sanctum.Consent.{Bootstrap, Source}

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")
  @aqua "formula:local.aqua"
  @claude "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_selection_#{System.unique_integer([:positive])}")

    seed_dir = Path.join(test_dir, "seed")
    copy_bundle!(Path.join(seed_dir, "components"))

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
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)

    {:ok, ctx: ctx}
  end

  defp head!(ctx, ref) do
    {:ok, [profile]} = Source.DB.profiles(ctx, ref)
    {:ok, row, refs} = ConsentStorage.get_head(ctx.athanor_id, profile.id)
    {profile, row, refs}
  end

  defp edge!(policy, from, to) do
    {:ok, blob} = Sanctum.Authority.Blob.parse(policy)
    {:ok, edge} = Sanctum.Authority.Blob.lookup_edge(blob, from, to, "")
    edge
  end

  test "the shipped assistant selects each shipped model's default profile", %{ctx: ctx} do
    {:ok, %{minted: minted, revised: []}} = Bootstrap.run(ctx)
    assert @aqua in minted and @claude in minted

    {claude, claude_head, claude_refs} = head!(ctx, @claude)
    assert claude.label == "default" and claude.kind == :owner
    assert claude_refs == []
    assert edge!(claude_head.resolved_policy, @claude, "@ingress") |> then(& &1.vault) == nil

    {_aqua, aqua_head, aqua_refs} = head!(ctx, @aqua)
    assert aqua_refs == []

    for model <- ~w(claude openai gemini grok openrouter) do
      {profile, _, _} = head!(ctx, "catalyst:local.#{model}")
      assert profile.label == "default"
      edge = edge!(aqua_head.resolved_policy, @aqua, "catalyst:local.#{model}")
      assert edge.vault == %{via: %{label: "default", binding_digest: nil}, projection: nil}
    end

    # A dependency without a credential need is not selected.
    assert edge!(aqua_head.resolved_policy, @aqua, "catalyst:local.files").vault == nil

    # Idempotent: nothing to mint or revise on the next boot.
    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
  end

  test "a person's own formula selects nothing at bootstrap", %{ctx: ctx} do
    # The athanor's own copy of the shipped formula, under its own name.
    shipped = ["components", "formulas", "local", "aqua", shipped_version("formulas", "aqua")]
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

    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "formula:local.mine" in minted

    {_mine, mine_head, _} = head!(ctx, "formula:local.mine")
    assert edge!(mine_head.resolved_policy, "formula:local.mine", @claude).vault == nil
  end

  test "a boot revises a bootstrap-only consent that lacks its selections, and no other", %{
    ctx: ctx
  } do
    {:ok, _} = Bootstrap.run(ctx)
    {aqua, head, _refs} = head!(ctx, @aqua)

    # An estate provisioned before selections existed: the same blob
    # without them, as the head.
    {:ok, %{"nodes" => nodes} = decoded} = Jason.decode(head.resolved_policy)

    stripped =
      Map.put(
        decoded,
        "nodes",
        Map.new(nodes, fn {ref, node} ->
          edges = Map.new(node["edges"], fn {k, e} -> {k, Map.delete(e, "vault")} end)
          {ref, Map.put(node, "edges", edges)}
        end)
      )

    {:ok, stripped_json} = Sanctum.JCS.encode(stripped)
    older = %{Map.from_struct(head) | revision: head.revision + 1, id: nil}

    {:ok, _} =
      ConsentStorage.insert_revision(
        older
        |> Map.take(
          ~w(athanor_id profile_id revision scope pinned_version invoke_mode shape_digest commit_digest activation granted_by granted_via)a
        )
        |> Map.merge(%{
          resolved_policy: stripped_json,
          blob_digest: Sanctum.JCS.hash_binary(stripped_json)
        }),
        [],
        head.id
      )

    {_, without, _} = head!(ctx, @aqua)
    assert edge!(without.resolved_policy, @aqua, @claude).vault == nil

    assert {:ok, %{minted: [], revised: [@aqua]}} = Bootstrap.run(ctx)
    {_, healed, _} = head!(ctx, @aqua)
    assert healed.revision == without.revision + 1
    assert healed.granted_via == "bootstrap"
    assert %{via: %{label: "default"}} = edge!(healed.resolved_policy, @aqua, @claude).vault

    # A head a person committed is theirs: the boot leaves it alone.
    {:ok, _} =
      ConsentStorage.insert_revision(
        older
        |> Map.take(
          ~w(athanor_id profile_id scope pinned_version invoke_mode shape_digest commit_digest activation granted_by)a
        )
        |> Map.merge(%{
          revision: healed.revision + 1,
          resolved_policy: stripped_json,
          blob_digest: Sanctum.JCS.hash_binary(stripped_json),
          granted_via: "interactive"
        }),
        [],
        healed.id
      )

    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
    {_, person, _} = head!(ctx, @aqua)
    assert person.granted_via == "interactive"
    assert edge!(person.resolved_policy, @aqua, @claude).vault == nil
    assert aqua.id == person.profile_id
  end

  defp shipped_version(plural, name) do
    [dir] = Path.wildcard(Path.join([@bundle, plural, "local", name, "*"]))
    Path.basename(dir)
  end

  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      target = Path.join(dest, Path.relative_to(src, @bundle))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
