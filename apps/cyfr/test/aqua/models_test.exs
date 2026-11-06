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

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create_personal(
        %{name: "Models #{n}", owner_user_id: user, created_by: user},
        ["models-#{n}"]
      )

    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
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
  # any agent's brain is installed is not known, so none reads as a model
  # to install.
  test "a catalyst listing that cannot be read leaves every agent's brain unread" do
    n = System.unique_integer([:positive])
    user = "local|idp|models-unread-#{n}"

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create_personal(
        %{name: "Models unread #{n}", owner_user_id: user, created_by: user},
        ["models-unread-#{n}"]
      )

    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}

    agents = [
      %{"name" => "aqua", "catalyst_ref" => "catalyst:local.claude"},
      %{"name" => "explorer", "catalyst_ref" => "catalyst:local.other"},
      %{"name" => "brainless", "catalyst_ref" => nil}
    ]

    assert Aqua.model_status(ctx, agents) == %{
             "aqua" => {:missing, "catalyst:local.claude"},
             "explorer" => {:missing, "catalyst:local.other"}
           }

    {:ok, _pending} =
      Arca.StorageProjectionChanges.begin_edit(
        Context.actor(ctx),
        "components",
        "catalysts/local/claude/1.0.0"
      )

    assert {:error, :catalyst_lookup_failed} = Aqua.AgentConfig.catalyst_listing(ctx)

    assert Aqua.model_status(ctx, agents) == %{
             "aqua" => {:model_unavailable, "catalyst:local.claude"},
             "explorer" => {:model_unavailable, "catalyst:local.other"}
           }
  end

  test "a model status needs a context" do
    assert Aqua.model_status(nil, [%{"name" => "aqua", "catalyst_ref" => "catalyst:local.x"}]) ==
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

  # A brain that mounts a program's own sign-in reads ready once its login
  # entry is bound on the catalyst's own consent and on the crew member's
  # edge into it, and its program has signed in. Before the binding, and
  # bound but before the sign-in, it waits on that sign-in, and the
  # readiness every hand-off applies refuses the member.
  test "a crew member whose brain mounts a login reads ready once its login entry is bound " <>
         "and its program signed in" do
    ctx = storage_root!("models_login")
    ref = "catalyst:local.loginbrain"

    # The athanor's own catalyst, under the test's own storage root.
    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "loginbrain", "0.1.0",
        manifest: %{
          "name" => "loginbrain",
          "type" => "catalyst",
          "version" => "0.1.0",
          "publisher" => "local",
          "needs" => %{
            "claude" => %{
              "type" => "login",
              "program" => "claude",
              "reason" => "to run the harness on your own plan",
              "required" => true
            }
          }
        },
        wasm: Cyfr.Test.Guests.wasm(:catalyst)
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)

    # A soul with no tools, so the member's closure is its brain alone.
    :ok =
      Arca.put(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file(), "---\n---\n\nsoul\n")

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.crew_file("harness"),
        "---\ncatalyst_ref: #{ref}\nmodel: harness-model\n---\n\nYou run the harness.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    member = [%{"name" => "harness", "catalyst_ref" => ref}]

    # A brain whose one need is a program's own sign-in asks for that, not
    # for a key.
    assert %{"harness" => {:needs_sign_in, resolved}} = Aqua.model_status(ctx, member)
    assert resolved =~ ref

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "login-claude",
        kind: "login",
        program: "claude"
      })

    commit!(ctx, ref, %{bindings: [%{need: "claude", entry_id: entry.id}]})

    commit!(ctx, Prima.AgentRef.ref("harness"), %{
      selections: [%{dep: ref, need: "claude", entry_id: entry.id}]
    })

    # Bound, its program not signed in yet: it still waits on the sign-in.
    assert Aqua.model_status(ctx, member) == %{"harness" => {:needs_sign_in, resolved}}
    assert Aqua.Crew.ready(ctx, "harness") == {:error, {:crew_unready, "harness", :not_signed_in}}

    # The sign-in whose command exited 0.
    :ok = Sanctum.Mount.signed_in(ctx, entry.id)

    assert Aqua.model_status(ctx, member) == %{"harness" => {:ready, resolved}}
    assert Aqua.Crew.ready(ctx, "harness") == :ok
  end

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

  # A context whose storage root is the test's own, removed when it ends.
  defp storage_root!(prefix) do
    test_path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(test_path) end)
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    %{Sanctum.TestContext.local() | origin: :interactive}
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
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
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
                "required" => true,
                "hosts" => ["api.statusmodel.test"]
              }
            },
            "caps" => %{"egress" => %{"domains" => ["api.statusmodel.test"]}}
          })
      })

    soul = [%{"name" => "aqua", "type" => Compendium.agent_soul_type(), "catalyst_ref" => ref}]
    {ctx, ref, "prof_statusmodel", fn -> Map.fetch!(Aqua.model_status(ctx, soul), "aqua") end}
  end
end
