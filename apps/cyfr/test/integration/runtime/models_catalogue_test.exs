# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ModelsCatalogueTest do
  @moduledoc """
  The console's model listing is a fan-out over the installed catalysts
  that speak `model/chat@1`, through the catalog: every such catalyst is
  named under `refs` at its versionless ref, one with no key connected is
  not run and lands under `errors` with the refusal its run would meet,
  one with a key is run, and a catalyst that speaks no contract is not
  asked at all. Opening AQUA's panel on an installation with no key
  leaves no failed run and nothing waiting on the person.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.SeedBundle
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "models_cat_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  test "every contract catalyst is listed; one without a key is an error, not a provider", %{
    ctx: ctx
  } do
    models = install!(ctx)

    assert {:ok, catalogue} = Aqua.models(ctx)

    expected_refs = Map.new(models, &{&1.name, &1.ref})
    assert catalogue["refs"] == expected_refs

    # No key is bound: no catalyst is run, and the refusal its listing
    # would meet is the provider's row.
    assert executions(ctx) == []
    assert catalogue["models"] == %{}

    assert Map.keys(catalogue["errors"]) |> Enum.sort() ==
             expected_refs |> Map.keys() |> Enum.sort()

    for {_name, message} <- catalogue["errors"] do
      assert message =~ Prima.Refusal.message(:connection_not_granted)
    end

    refute Map.has_key?(catalogue["refs"], "files")

    # The console's reading of it: nothing to pick from, nothing dropped.
    assert %{models: %{}, refs: refs} = PrismWeb.ModelCatalog.parse(catalogue)
    assert refs == catalogue["refs"]
  end

  # The panel loads the catalogue on every pane mount: with no key
  # connected, an opening leaves no failed run, so nothing waits on the
  # person with a Retry the server refuses.
  test "opening the panel with no key leaves no failed run and nothing waiting", %{ctx: ctx} do
    install!(ctx)

    :ok = PrismWeb.ModelCatalog.load(ctx)
    assert_receive {:list_models_result, _tag, {:ok, %{"errors" => errors}}}, 30_000
    assert map_size(errors) > 0

    assert {:ok, []} =
             Arca.Execution.unresolved_failures(Sanctum.Context.actor(ctx), ctx.user_id, [])

    assert {:ok, waiting} = Cyfr.Providers.Attention.waiting(ctx, ctx.user_id)
    assert Enum.filter(waiting, &(to_string(&1.kind) == "failed_run")) == []
  end

  # Consent still decides what runs: a catalyst with its key bound is
  # asked, and only it.
  test "a catalyst whose key is bound is still run", %{ctx: ctx} do
    install!(ctx)
    ref = "catalyst:local.openai"

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "openai-key",
        kind: "api_key",
        fields: %{"OPENAI_API_KEY" => "sk-test"},
        destination: %{"hosts" => ["api.openai.com"]}
      })

    commit!(ctx, ref, %{bindings: [%{need: "api_key", entry_id: entry.id}]})

    # The revision admits the person's own origin, which the panel runs under.
    assert {:ok, catalogue} = Aqua.models(%{ctx | origin: :interactive})
    assert [reference] = Enum.map(executions(ctx), & &1.reference)
    assert reference =~ ref
    refute catalogue["errors"]["openai"] == Prima.Refusal.message(:connection_not_granted)
  end

  # A login bound to a program not signed in yet is no grant to make: the
  # catalyst is still not run, and its row says what waits.
  test "a bound login waiting on sign-in keeps the actual state", %{ctx: ctx} do
    install!(ctx)
    ctx = %{ctx | origin: :interactive}
    ref = "catalyst:local.claude-code"

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude-login",
        kind: "login",
        program: "claude"
      })

    commit!(ctx, ref, %{bindings: [%{need: "claude", entry_id: entry.id}]})

    assert {:ok, catalogue} = Aqua.models(ctx)
    assert executions(ctx) == []

    assert catalogue["errors"]["claude-code"] ==
             "The login entry bound to claude is not signed in; sign it in on the Programs page."

    assert catalogue["errors"]["openai-codex"] == Prima.Refusal.message(:connection_not_granted)
  end

  # The seed's model catalysts and its files catalyst (which speaks no
  # contract), installed and consented by the bootstrap, nothing bound.
  defp install!(ctx) do
    models = SeedBundle.model_chat_units(@seed_root)
    files = SeedBundle.local_unit!(@seed_root, "catalysts", "files")

    for unit <- models ++ [files] do
      segments = ["components" | String.split(unit.rel, "/")]
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), segments)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, segments)
    end

    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    for unit <- models, do: assert(unit.ref in minted, "#{unit.ref} not minted")

    # The athanor is filled by hand above; marked so, a listing starts no
    # fill of its own behind this test.
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
    models
  end

  defp executions(ctx), do: Arca.Execution.list(Sanctum.Context.actor(ctx), status: :all)

  # A person's walk, from their own page.
  defp commit!(ctx, ref, over) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, over)
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end
end
