# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ModelsCatalogueTest do
  @moduledoc """
  The console's model listing is a fan-out over the installed catalysts
  that speak `model/chat@1`, through the catalog: every such catalyst is
  named under `refs` at its versionless ref, one that binds no key has
  its key read refused and lands under `errors`, and a catalyst that
  speaks no contract is not asked at all.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @models ~w(claude gemini)

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "models_cat_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "every contract catalyst is listed; one without a key is an error, not a provider", %{
    ctx: ctx
  } do
    for name <- @models ++ ["files"] do
      [version_dir] = Path.wildcard(Path.join(@seed_root, "components/catalysts/local/#{name}/*"))
      unit = ["components", "catalysts", "local", name, Path.basename(version_dir)]
      :ok = Arca.Overlay.pull_shipped(ctx, unit)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    end

    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "catalyst:local.claude" in minted

    # The estate is filled by hand above; marked so, a listing starts no
    # fill of its own behind this test.
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)

    assert {:ok, catalogue} = Cyfr.Models.catalogue(ctx)

    assert catalogue["refs"] == %{
             "claude" => "catalyst:local.claude",
             "gemini" => "catalyst:local.gemini"
           }

    # No key is bound on either: the key read is refused before anything
    # is dialled, and that refusal is the provider's row.
    assert catalogue["models"] == %{}
    assert Map.keys(catalogue["errors"]) |> Enum.sort() == ["claude", "gemini"]
    assert catalogue["errors"]["claude"] =~ "ANTHROPIC_API_KEY not granted"
    assert catalogue["errors"]["gemini"] =~ "GEMINI_API_KEY not granted"
    refute Map.has_key?(catalogue["refs"], "files")

    # The console's reading of it: nothing to pick from, nothing dropped.
    assert %{models: %{}, refs: refs} = PrismWeb.ModelCatalog.parse(catalogue)
    assert refs == catalogue["refs"]
  end
end
