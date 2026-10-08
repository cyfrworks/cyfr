# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelsTest do
  @moduledoc """
  The model listing's refusals: the listing reads the athanor's catalysts
  through the component domain's facade and refuses as it refuses, and a
  model status needs a context and keeps a damaged or unreadable consent
  apart from a key to connect. The assistant's root roster is
  `Aqua.FacadeTest`'s.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  # Minimal valid WASM with a `run` export: enough to publish a row.
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the listing refuses a caller the component facts refuse, and runs nothing" do
    local = Sanctum.TestContext.local()

    anonymous = %{local | authenticated: false}
    assert {:error, :forbidden} = Aqua.models(anonymous)

    unfocused = %{local | athanor_id: nil, scope: :platform}
    assert {:error, :forbidden} = Aqua.models(unfocused)

    no_read = %{local | permissions: MapSet.new([:execute])}
    assert {:error, :forbidden} = Aqua.models(no_read)

    assert {:error, :forbidden} = Aqua.models(Context.enter_guest(local))
  end

  test "an athanor whose component index is behind answers unavailable, not an empty listing" do
    n = System.unique_integer([:positive])
    user = "local|idp|models-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Models #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}

    assert {:ok, %{"models" => %{}, "refs" => %{}, "errors" => %{}}} = Aqua.models(ctx)

    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(
        Context.actor(ctx),
        "components",
        "catalysts/local/claude/1.0.0"
      )

    assert {:error, :unavailable} = Aqua.models(ctx)
  end

  # A catalyst listing that cannot be read is not an empty one: whether
  # any soul's model is installed is not known, so none reads as a model
  # to install.
  test "a catalyst listing that cannot be read leaves every soul's model unread" do
    n = System.unique_integer([:positive])
    user = "local|idp|models-unread-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Models unread #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}
    soul = Compendium.agent_soul_type()

    agents = [
      %{"type" => soul, "catalyst_ref" => "catalyst:local.claude"},
      %{"type" => soul, "catalyst_ref" => "catalyst:local.other"}
    ]

    assert Aqua.model_status(ctx, agents) == %{
             "catalyst:local.claude" => {:missing, "catalyst:local.claude"},
             "catalyst:local.other" => {:missing, "catalyst:local.other"}
           }

    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(
        Context.actor(ctx),
        "components",
        "catalysts/local/claude/1.0.0"
      )

    assert {:error, :catalyst_lookup_failed} = Aqua.AgentConfig.catalyst_listing(ctx)

    assert Aqua.model_status(ctx, agents) == %{
             "catalyst:local.claude" => {:model_unavailable, "catalyst:local.claude"},
             "catalyst:local.other" => {:model_unavailable, "catalyst:local.other"}
           }
  end

  test "a model status needs a context" do
    assert Aqua.model_status(nil, [%{"type" => "soul", "catalyst_ref" => "catalyst:local.x"}]) ==
             %{}
  end

  # A model whose own consent exists but is damaged, or that the store
  # could not answer, is no key to connect: connecting cannot repair a
  # consent that exists. One never granted is a key to connect.
  @tag :capture_log
  test "a model whose consent is damaged or unreadable says so, never that it needs a key" do
    {ctx, ref, profile, status} = status_model!()

    :ok =
      ConsentFixtures.seed_profile!(ctx, %{
        id: profile,
        source_ref: ref,
        kind: :owner,
        label: "default",
        status: :active
      })

    assert {:needs_key, resolved} = status.()
    assert resolved =~ ref

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: profile, source_ref: ref, kind: :owner, label: "default", status: :active},
        %{
          id: "cons_statusmodel",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: "{}",
          activation: %{ref => "sha256:act"},
          vault_refs: []
        }
      )

    :ok = ConsentFixtures.hand_edit_head!(ctx, profile, scope: "sideways")
    assert {:consent_damaged, ^resolved} = status.()

    :ok = ConsentFixtures.hand_edit_head!(ctx, profile, scope: "versionless")
    Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
    assert {:consent_unavailable, ^resolved} = status.()
  end

  # A profile row that does not decode, or a profile list the store could
  # not answer, reads as a head that does: damaged or unanswered, never a
  # key to connect.
  @tag :capture_log
  test "a model whose profile row is damaged or unreadable says so, never that it needs a key" do
    {ctx, ref, profile, status} = status_model!()

    :ok =
      ConsentFixtures.seed_profile!(ctx, %{
        id: profile,
        source_ref: ref,
        kind: :owner,
        label: "default",
        status: :active
      })

    assert {:needs_key, resolved} = status.()

    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == ^profile
        ),
        set: [kind: "sideways"]
      )

    assert {:consent_damaged, ^resolved} = status.()

    Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")
    assert {:consent_unavailable, ^resolved} = status.()
  end

  # A model catalyst whose one need is a key, published under a storage
  # root of the test's own: the context, its ref, the id its owner
  # profile takes, and a read of its status as the soul names it.
  defp status_model! do
    test_path =
      Path.join(System.tmp_dir!(), "models_status_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local()
    ref = "catalyst:local.statusmodel"

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "statusmodel",
        version: "0.1.0",
        type: "catalyst",
        manifest:
          Jason.encode!(%{
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:statusmodel.test",
                "reason" => "to call the model with your key",
                "fields" => ["STATUSMODEL_API_KEY"],
                "required" => true
              }
            }
          })
      })

    soul = [%{"type" => Compendium.agent_soul_type(), "catalyst_ref" => ref}]
    {ctx, ref, "prof_statusmodel", fn -> Map.fetch!(Aqua.model_status(ctx, soul), ref) end}
  end
end
