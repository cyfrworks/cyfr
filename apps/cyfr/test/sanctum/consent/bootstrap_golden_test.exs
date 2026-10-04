# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BootstrapGoldenTest do
  @moduledoc """
  What baseline consent grants, pinned: every athanor is minted from the
  tracked bundle, and each executable local component and each shipped
  agent gets one consent whose blob (`resolved_policy`, already JCS) is a
  pure function of the bundle's manifests and the shipped agent files. This compares those blobs byte for byte against
  `test/support/fixtures/consent_golden.json` — a diff is a deliberate
  change to what strangers on a `*` server are granted, and is bumped by
  re-recording (`CYFR_GOLDEN_RECORD=1 mix test <this file>`).

  Two cases are pinned: the server's own mint of an athanor no instance
  entry is offered to, and a person's first sign-in to an athanor while
  one instance entry is offered to them. Every catalyst the bundle ships
  reads its key itself (its needs declare no attach rule), so no shipped
  need can be met by an instance entry, and the second case binds
  nothing: its blobs are the first's.

  Only the blob is golden: the activation and its digests move with every
  wasm rebuild, so they are asserted present, not pinned. The origins a
  seeded grant admits are asserted beside it: `interactive` and
  `programmatic`, the operator's own first-party install, and never a
  schedule or a webhook.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap}

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")
  @golden Path.expand("../../support/fixtures/consent_golden.json", __DIR__)

  @without "no_instance_entry"
  @with_one "one_offered_instance_entry"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_golden_#{:rand.uniform(1_000_000)}")
    seed_dir = Path.join(test_dir, "seed")
    bundle_dir = Path.join(seed_dir, "components")
    copy_bundle!(bundle_dir)
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    prev_base = Application.get_env(:arca, :base_path)
    prev_seed = Application.get_env(:arca, :seed_path)
    Application.put_env(:arca, :base_path, test_dir)
    Application.put_env(:arca, :seed_path, seed_dir)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(test_dir)
    end)

    :ok
  end

  # An athanor filled from the bundle as a fill fills it: the bundle copied
  # in and the scan minting its rows, the AQUA tree copied in and indexed.
  defp filled!(name) do
    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: name,
        slug: "golden-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: athanor.id, scope: :athanor)
    {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), "components")
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), "aqua")
    {:ok, _rows} = Compendium.AgentIndex.sync(ctx)
    ctx
  end

  # A person signed in to the athanor: who a first sign-in's walk runs as.
  defp person!(%Sanctum.Context{athanor_id: athanor_id}) do
    {ctx, _user} =
      Sanctum.TestContext.person!(
        Sanctum.Context.build(
          user_id: "local|local|golden-#{System.unique_integer([:positive])}",
          provider: "local",
          namespace: "golden",
          athanor_id: athanor_id,
          permissions: Sanctum.Context.person_permissions(),
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    ctx
  end

  defp blobs!(ctx, minted, granted_by) do
    Map.new(minted, fn ref ->
      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
      {:ok, row, _refs} = Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id)
      assert row.granted_by == granted_by
      {:ok, consent} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      assert is_map(consent.activation) and consent.activation != %{}
      assert is_binary(consent.shape_digest) and consent.shape_digest != ""
      assert consent.admitted_origins == [:interactive, :programmatic]
      {ref, consent.resolved_policy}
    end)
  end

  test "the consent blob minted per bundle component is byte-stable" do
    # The server's own mint: `granted_by` is the constant "system:bootstrap".
    seeded = filled!("Golden")
    {:ok, %{minted: minted}} = Bootstrap.run(seeded)
    assert minted != []
    without = blobs!(seeded, minted, "system:bootstrap")

    # A person's first sign-in while the instance offers them one entry
    # of a shipped catalyst's provider.
    {:ok, _entry} =
      Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
        name: "golden-company",
        kind: "api_key",
        provider_hint: "anthropic.com",
        field_names: ~s(["ANTHROPIC_API_KEY"]),
        destination:
          ~s({"hosts":["api.anthropic.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
        sealed_payload: "sealed",
        binding_digest: "sha256:golden",
        audience: "everyone",
        created_by: "usr_admin"
      })

    person = person!(filled!("Golden offered"))
    {:ok, %{minted: offered_minted}} = Bootstrap.run(person)
    with_one = blobs!(person, offered_minted, person.user_id)

    blobs = %{@without => without, @with_one => with_one}

    if System.get_env("CYFR_GOLDEN_RECORD") == "1" do
      File.write!(@golden, Jason.encode!(blobs, pretty: true) <> "\n")
      flunk("golden re-recorded at #{@golden}; run again without CYFR_GOLDEN_RECORD")
    end

    assert File.exists?(@golden), "no golden fixture; record one with CYFR_GOLDEN_RECORD=1"
    golden = @golden |> File.read!() |> Jason.decode!()

    assert Map.keys(golden) |> Enum.sort() == Enum.sort([@without, @with_one])

    for {case_name, case_blobs} <- blobs do
      assert Map.keys(case_blobs) |> Enum.sort() == Map.keys(golden[case_name]) |> Enum.sort(),
             "the set of bundle components bootstrap mints for changed (#{case_name})"

      for {ref, blob} <- case_blobs do
        assert blob == golden[case_name][ref],
               "baseline consent for #{ref} changed (#{case_name}) — if deliberate, " <>
                 "re-record with CYFR_GOLDEN_RECORD=1"
      end
    end

    # No shipped need can be met by an instance entry: the offered entry
    # binds nothing.
    assert with_one == without
    refute Enum.any?(Map.values(with_one), &(&1 =~ ~s("scope":"instance")))
  end

  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Prima.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      target = Path.join(dest, Path.relative_to(src, @bundle))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
