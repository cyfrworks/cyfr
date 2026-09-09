# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.BootstrapFirstRunTest do
  @moduledoc """
  The fresh-install acceptance arc over the REAL tracked bundle: the
  re-released components register from the repo tree, bootstrap mints
  their consents from the caps blocks, and a needs-declaring component
  reads not-ready until a vault entry is bound through the walk.

  The moonmoon69 catalysts arrive only via registry pull, so on a tree
  without them AQUA and list-models register (a manifest's dependency
  refs only have to parse) but their bootstrap legitimately skips as
  unresolvable — asserted as the CI truth rather than worked around. The
  full pulled-bundle first run is `Sanctum.Provisioning`'s closure pull.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Source

  @seed_root Path.expand("../../../../seed", __DIR__)
  @bundled ["catalysts/local/files/0.5.1", "catalysts/local/http/1.1.1"]
  # The AQUA formula at its newest shipped version, found rather than
  # pinned: a release bump must not leave this naming a directory that no
  # longer ships.
  @shipped_aqua [@seed_root, "components/formulas/local/aqua/*"]
                |> Path.join()
                |> Path.wildcard()
                |> Enum.sort_by(fn path ->
                  path |> Path.basename() |> String.split(".") |> Enum.map(&String.to_integer/1)
                end)
                |> List.last()
                |> Path.relative_to(Path.join(@seed_root, "components"))
  @registry_dep_formulas ["formulas/local/list-models/0.6.1", @shipped_aqua]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "first_run_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # The REAL tracked bundle, served in place through the seed overlay —
    # the production-true path: a real install copies nothing, the union
    # answers and the scan mints rows.
    original_seed_path = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_seed_path,
        do: Application.put_env(:cyfr, :seed_path, original_seed_path),
        else: Application.delete_env(:cyfr, :seed_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Register a tracked bundle version the way the auto-indexer does: the
  # overlay union serves the seed bytes in place — nothing is copied.
  defp stage_and_register(ctx, rel) do
    segments = ["components" | String.split(rel, "/")]
    Compendium.Registry.register_from_arca(ctx, segments)
  end

  test "the tracked bundle registers, bootstraps and loads from its caps blocks", %{ctx: ctx} do
    for rel <- @bundled do
      assert {:ok, _} = stage_and_register(ctx, rel), rel
    end

    # The model catalysts are name-level moonmoon69 refs that arrive only
    # via registry pull (the closure pull at provisioning on a real
    # install). Both formulas declare them OPTIONAL, so with none installed
    # each activation covers what is present and bootstrap mints both — a
    # server with no registry boots with its whole bundle consented.
    for rel <- @registry_dep_formulas do
      assert {:ok, _} = stage_and_register(ctx, rel), rel
    end

    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "catalyst:local.files" in minted
    assert "catalyst:local.http" in minted
    assert "formula:local.aqua" in minted
    assert "formula:local.list-models" in minted

    # list-models invokes its providers as children and asks for nothing
    # else, so with none installed its activation is itself alone.
    {:ok, [list_models_profile]} = Source.DB.profiles(ctx, "formula:local.list-models")
    {:ok, list_models_consent} = Source.DB.head_consent(ctx, list_models_profile.id)
    assert Map.keys(list_models_consent.activation) == ["formula:local.list-models"]

    {:ok, [aqua_profile]} = Source.DB.profiles(ctx, "formula:local.aqua")
    {:ok, aqua_consent} = Source.DB.head_consent(ctx, aqua_profile.id)

    assert Map.keys(aqua_consent.activation) |> Enum.sort() ==
             ["catalyst:local.files", "catalyst:local.http", "formula:local.aqua"]

    # Each minted consent loads through the production source, and the
    # blob's ingress edge carries the manifest's declared ask.
    {:ok, [files_profile]} = Source.DB.profiles(ctx, "catalyst:local.files")
    {:ok, files_component} = Compendium.Registry.get_latest(ctx, "files", "local", "catalyst")
    {:ok, files_live} = Compendium.Activation.resolve_verified(ctx, files_component)

    assert {:ok, files_auth, _} =
             Loader.load_root(ctx, files_profile, source: Source.DB, live: {:ok, files_live})

    # The shipped grant is data/ only — components/ is an explicit, rare
    # capability, not a file tool's default reach.
    assert files_auth.resources.storage.paths == ["data/"]
    assert "write" in files_auth.resources.storage.actions

    {:ok, [http_profile]} = Source.DB.profiles(ctx, "catalyst:local.http")
    {:ok, http_component} = Compendium.Registry.get_latest(ctx, "http", "local", "catalyst")
    {:ok, http_live} = Compendium.Activation.resolve_verified(ctx, http_component)

    assert {:ok, http_auth, _} =
             Loader.load_root(ctx, http_profile, source: Source.DB, live: {:ok, http_live})

    assert http_auth.resources.egress.domains == ["*"]
    # The one component allowed plaintext says so explicitly.
    assert Enum.sort(http_auth.resources.egress.schemes) == ["http", "https"]
    assert Sanctum.Authority.limits(http_auth).rate_limit == %{requests: 60, window: "1m"}
  end

  test "a needs-declaring catalyst is not ready until its vault entry binds", %{ctx: ctx} do
    # The moonmoon69 re-release shape, published as a synthetic catalyst
    # so CI needs no registry pull.
    wasm = File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

    manifest = %{
      "name" => "llm",
      "version" => "1.1.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:anthropic.com",
          "reason" => "to call the Anthropic API with your key",
          "fields" => ["ANTHROPIC_API_KEY"]
        }
      },
      "caps" => %{
        "egress" => %{"domains" => ["api.anthropic.com"], "methods" => ["GET", "POST"]},
        "limits" => %{"timeout" => "3m"}
      }
    }

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, wasm, %{
        name: "llm",
        version: "1.1.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "catalyst:local.llm" in minted

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "catalyst:local.llm")
    refute plan.ready
    assert Enum.any?(plan.consent.needs, &(&1[:need] == "api_key" and not &1.satisfied))

    # The operator creates a vault entry and binds it through the walk.
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "My Anthropic",
        kind: "api_key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-first-run"}
      })

    {:ok, walk_plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.llm"})
    decisions = %{ref: "catalyst:local.llm", bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: walk_plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: walk_plan.expected_consent_revision
      })

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "catalyst:local.llm")
    assert plan.ready

    # And the projected field dispenses through the vault path.
    {:ok, [profile]} = Source.DB.profiles(ctx, "catalyst:local.llm")
    {:ok, component} = Compendium.Registry.get_latest(ctx, "llm", "local", "catalyst")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

    assert {:ok, auth, _} =
             Loader.load_root(ctx, profile, source: Source.DB, live: {:ok, live})

    assert {:ok, secrets} = Sanctum.VaultReader.fetch(ctx, auth.resources.vault)
    assert secrets == %{"ANTHROPIC_API_KEY" => "sk-first-run"}
  end
end
