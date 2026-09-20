# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.ComponentsTest do
  @moduledoc """
  The component-facts port, and the one thing it exists to keep straight.

  Consent is derived from what a component declares, and the identity
  domain cannot read a manifest, an activation graph or the install media
  for itself. It asks through `Sanctum.Consent.Components`, which the
  component domain answers (`Compendium.ConsentFacts`).

  An estate whose facts cannot be read is not an estate that holds
  nothing: a walk that mistook the two would skip every source as
  unvouched and report a clean, empty mint, and a shape derived from no
  manifest at all would grant nothing and read as a component that asks
  for nothing. So the port answers one word of its own, and these cases
  hold it apart from the two it must never be confused with — the
  component does not exist, and the consent does not cover it.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Components
  alias Sanctum.Consent.ShapeDerivation

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_components_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Cyfr.Test.SeedBundle.isolate!()

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # The port with no implementation written: what a deployment whose
  # boot did not wire it looks like from inside the auth domain.
  defp without_facts(fun) do
    previous = Application.get_env(:sanctum, :consent_components)
    Application.delete_env(:sanctum, :consent_components)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:sanctum, :consent_components, previous)
    end
  end

  defp ship!(ctx, name, type) do
    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, type, "local", name, "1.0.0",
        manifest: %{
          "name" => name,
          "type" => type,
          "version" => "1.0.0",
          "publisher" => "local",
          "description" => "component facts test"
        },
        wasm: @wasm
      )

    component
  end

  test "the one implementation is the component domain's, and it answers the port" do
    assert Components.impl() == Compendium.ConsentFacts

    behaviours =
      Compendium.ConsentFacts.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Sanctum.Consent.Components in behaviours
  end

  test "every call refuses in its own word when no implementation is written", %{ctx: ctx} do
    row = ship!(ctx, "facts-shipped", "reagent")

    without_facts(fn ->
      assert {:error, :component_facts_unavailable} = Components.resolve(ctx, row)
      assert {:error, :component_facts_unavailable} = Components.resolve_verified(ctx, row)
      assert {:error, :component_facts_unavailable} = Components.agent_rows(ctx)
      assert {:error, :component_facts_unavailable} = Components.shipped_nodes(ctx, [row])

      assert {:error, :component_facts_unavailable} =
               Components.get_latest(ctx, "facts-shipped", "local", "reagent")

      assert {:error, :component_facts_unavailable} =
               Components.get_component(ctx, "facts-shipped", "1.0.0", "local", "reagent")
    end)
  end

  test "unreadable facts, an absent component and a denial are three different words", %{ctx: ctx} do
    ship!(ctx, "facts-present", "reagent")

    # The estate holds no component by that name: `:not_found`.
    assert {:error, :not_found} = Components.get_latest(ctx, "facts-absent", "local", "reagent")

    # It holds this one, at this version, and not at another.
    assert {:ok, _} = Components.get_component(ctx, "facts-present", "1.0.0", "local", "reagent")

    assert {:error, :not_found} =
             Components.get_component(ctx, "facts-present", "9.9.9", "local", "reagent")

    # The facts cannot be read at all: a third word, and not either of
    # those. A consent decision that took this for `:not_found` would
    # report an estate that holds nothing.
    without_facts(fn ->
      assert {:error, :component_facts_unavailable} =
               Components.get_latest(ctx, "facts-present", "local", "reagent")
    end)

    # And neither is any refusal the consent itself renders: `Authz`'s
    # vocabulary is closed, and a word outside it falls through to the
    # generic sentence. Both of these do, which is what says the port's
    # word is not a denial wearing another name.
    generic = Sanctum.Consent.Authz.message(:invalid_request)
    assert Sanctum.Consent.Authz.message(:component_facts_unavailable) == generic
    assert Sanctum.Consent.Authz.message(:guest_plane) != generic
  end

  test "a shape derived while the facts are unreadable refuses rather than deriving nothing",
       %{ctx: ctx} do
    ship!(ctx, "facts-shape", "reagent")

    assert {:ok, %{needs: _, caps: _}} =
             ShapeDerivation.shape_input(ctx, "reagent:local.facts-shape")

    without_facts(fn ->
      assert {:error, :component_facts_unavailable} =
               ShapeDerivation.shape_input(ctx, "reagent:local.facts-shape")
    end)
  end

  test "a bootstrap walk over unreadable facts refuses; it does not report an empty mint",
       %{ctx: ctx} do
    ship!(ctx, "facts-mint", "reagent")

    without_facts(fn ->
      assert {:error, {:component_facts, :component_facts_unavailable}} = Bootstrap.run(ctx)
    end)

    # And with the facts back, the same walk mints — so the refusal above
    # was the port's and not an empty estate.
    assert {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "reagent:local.facts-mint" in minted
  end
end
