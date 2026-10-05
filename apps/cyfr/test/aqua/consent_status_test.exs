# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConsentStatusTest do
  @moduledoc """
  Whether a consent still covers its source is answered as a state or a
  typed refusal, never as silence: a source with nothing to judge is
  `:absent`, a context with no athanor is forbidden, a store that
  cannot answer fails the whole list rather than reading as "nothing is
  stale", and a head the store cannot answer is an outage, never damage.
  """

  use ExUnit.Case, async: false

  alias Aqua.ConsentStatus
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "consent_status_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    n = System.unique_integer([:positive])
    user = "local|idp|consent-status-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Consent #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
    {:ok, ctx: %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}}
  end

  test "the actions the consent lacks are named in the manifest's order" do
    declared = ~w(aqua.get notes.keep notes.list schedule.list)

    assert ConsentStatus.missing(declared, ~w(aqua.get schedule.list)) ==
             ~w(notes.keep notes.list)

    assert ConsentStatus.missing(declared, declared) == []
    assert ConsentStatus.missing([], ~w(aqua.get)) == []
  end

  test "a source with no row and no profile has no consent to judge", %{ctx: ctx} do
    assert {:ok, :absent} = ConsentStatus.state(ctx, "formula:local.nothing-here")
    assert {:ok, :absent} = Aqua.consent_state(ctx, "formula:local.nothing-here")

    # The soul of an athanor whose tree holds none.
    assert {:ok, :absent} = Aqua.consent_state(ctx)
  end

  test "an athanor with nothing drifted lists nothing, as a list", %{ctx: ctx} do
    assert {:ok, []} = ConsentStatus.stale_refs(ctx)
    assert {:ok, []} = Aqua.stale_consent_refs(ctx)
  end

  test "a context that names no athanor is refused, never read as current", %{ctx: ctx} do
    unfocused = %{ctx | athanor_id: nil}

    assert {:error, :forbidden} = ConsentStatus.state(unfocused, "formula:local.x")
    assert {:error, :forbidden} = Aqua.consent_state(unfocused)
    assert {:error, :forbidden} = Aqua.stale_consent_refs(unfocused)
  end

  test "an outage fails the whole list; it is never an empty one", %{ctx: ctx} do
    assert {:ok, []} = Aqua.stale_consent_refs(ctx)

    # The agent index is behind its tree: which agents there are cannot
    # be said, so neither can whether any of them drifted.
    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(Context.actor(ctx), "aqua", "roles/scout.md")

    assert {:error, :unavailable} = Aqua.stale_consent_refs(ctx)
  end

  # The loader answers a head three ways; a page that read an outage as
  # damage would tell the person their grant is broken while the store is
  # only away.
  @tag :capture_log
  test "a head the store cannot answer is an outage; a damaged or missing one is damage",
       %{ctx: ctx} do
    ref = "reagent:local.status-head"

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "status-head",
        version: "1.0.0",
        type: "reagent"
      })

    profile = %{
      id: "prof-status-head",
      kind: :owner,
      source_ref: ref,
      label: "default",
      status: :active
    }

    # An active profile with no head.
    :ok = ConsentFixtures.seed_profile!(ctx, profile)
    assert {:error, :corrupt} = ConsentStatus.state(ctx, ref)

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-status-head",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-status",
        commit_digest: "sha256:commit-status",
        resolved_policy: "{}",
        activation: %{ref => "sha256:act"},
        vault_refs: []
      })

    :ok = ConsentFixtures.hand_edit_head!(ctx, profile.id, scope: "sideways")
    assert {:error, :corrupt} = ConsentStatus.state(ctx, ref)

    :ok = ConsentFixtures.hand_edit_head!(ctx, profile.id, scope: "versionless")
    Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
    assert {:error, :unavailable} = ConsentStatus.state(ctx, ref)
  end

  # The one reading of a load's refusal, which the model status reads the
  # assistant's own load through: damage of the root's head, of a lender
  # or of the stored grant is damage, a store that did not answer the
  # head or a lender is an outage, and an answer it does not name is an
  # outage, never damage and never a state.
  test "a load's refusal reads as a state, as damage, or as an outage" do
    for {reason, reading} <- [
          {{:consent_required, %{profile_id: "prof_x"}}, {:ok, :stale}},
          {:no_profile, {:ok, :absent}},
          {{:ambiguous, ["prof_a", "prof_b"]}, {:ok, :absent}},
          {:no_athanor, {:error, :forbidden}},
          {{:head_corrupt, "prof_x"}, {:error, :corrupt}},
          {{:no_head_consent, "prof_x"}, {:error, :corrupt}},
          {{:blob_digest_mismatch, "sha256:0"}, {:error, :corrupt}},
          {{:lender_corrupt, "catalyst:local.claude", "prof_y"}, {:error, :corrupt}},
          {{:head_unavailable, "prof_x"}, {:error, :unavailable}},
          {{:lender_unavailable, "catalyst:local.claude"}, {:error, :unavailable}},
          {:database_error, {:error, :unavailable}}
        ] do
      assert {reason, ConsentStatus.classify_refusal(reason)} == {reason, reading}
    end
  end
end
