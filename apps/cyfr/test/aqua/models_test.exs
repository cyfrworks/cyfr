# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelsTest do
  @moduledoc """
  The model listing's refusals: the listing reads the athanor's catalysts
  through the component domain's facade and refuses as it refuses, and a
  model status needs a context and keeps a damaged or unreadable consent
  apart from a key to connect, and a brain whose grant is all it needs
  asks for the grant. The assistant's root roster is
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

  test "a models run reads as its list, the provider's refusal of the key, or what else it said" do
    envelope = &{:ok, %{result: &1}}

    assert Aqua.Models.listed(
             envelope.(%{
               "status" => 200,
               "data" => %{"models" => [%{"id" => "m-1"}, %{"id" => ""}]}
             })
           ) == {:ok, ["m-1"]}

    assert Aqua.Models.listed(envelope.(%{"status" => 200, "data" => %{"models" => []}})) ==
             {:ok, []}

    # Only the contract's authentication refusal is a refused key.
    assert Aqua.Models.listed(
             envelope.(%{
               "status" => 401,
               "error" => %{"type" => "authentication", "message" => "invalid x-api-key"}
             })
           ) == {:refused, "invalid x-api-key"}

    assert Aqua.Models.listed(
             envelope.(%{
               "status" => 529,
               "error" => %{"type" => "overloaded", "message" => "try again later"}
             })
           ) == {:error, "try again later"}

    assert Aqua.Models.listed(envelope.(%{"status" => 200, "data" => %{}})) ==
             {:error, "the catalyst answered no model list"}
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

  # What is known of a program is read and never asked: it needs no box,
  # and a name with no row standing as a program of the kind knows nothing.
  test "what is known of a program is its row's at its epoch, and asks nothing" do
    ctx = Sanctum.TestContext.local()
    actor = Context.actor(ctx)
    name = "known-#{System.unique_integer([:positive])}"
    nothing = %{account: nil, listing: nil}
    agent = %{"program" => name}
    assert Aqua.known_program(ctx, agent) == nothing

    {:ok, row} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => "cyfr-claude-code claude", "env" => %{}})
      })

    assert Aqua.known_program(ctx, agent) == nothing

    listing = %{models: [%{id: "opus", name: "Opus", efforts: []}], access: []}

    for {what, value} <- [account: :signed_out, listing: listing] do
      :ok = Arca.Cache.put(Arca.Cache.Keys.brain_known(actor, row.id, row.epoch, what), value)
    end

    assert Aqua.known_program(ctx, agent) == %{account: :signed_out, listing: listing}
    assert Aqua.known_program(ctx, %{"catalyst_ref" => "catalyst:local.x"}) == nothing

    {:ok, _raised} = Arca.McpServerStorage.bump_epoch(actor, row.id)
    assert Aqua.known_program(ctx, agent) == nothing
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

  # A person's walk, from their own page.
  # A brain with no grant to stand on asks for what connecting it takes:
  # the grant alone when it needs nothing else of the person, never a key
  # it does not need, both before its first grant and after a revocation.
  test "a brain whose grant is all it needs asks for the grant, never granted or revoked" do
    ctx = storage_root!("models_grant_only")
    chat_brain!(ctx, "open", %{})

    chat_brain!(ctx, "keyed", %{
      "api_key" => %{
        "type" => "api_key:keyed.test",
        "reason" => "to call the model with your key",
        "fields" => ["KEYED_API_KEY"],
        "required" => true,
        "hosts" => ["api.keyed.test"]
      }
    })

    assert states(ctx) == %{"keyed" => :needs_key, "open" => :needs_grant}

    commit!(ctx, "catalyst:local.open", %{})
    assert states(ctx) == %{"keyed" => :needs_key, "open" => :ready}

    {:ok, %{revoked: [_]}} = Sanctum.Consent.revoke_source(ctx, "catalyst:local.open")
    assert states(ctx) == %{"keyed" => :needs_key, "open" => :needs_grant}
  end

  # The limit: an ungranted plan carries no binding, so a brain whose key
  # was bound before its grant was revoked asks for the key again, as one
  # never connected does.
  test "a keyed brain whose grant was revoked asks for its key" do
    ctx = storage_root!("models_revoked_key")

    chat_brain!(ctx, "keyed", %{
      "api_key" => %{
        "type" => "api_key:keyed.test",
        "reason" => "to call the model with your key",
        "fields" => ["KEYED_API_KEY"],
        "required" => true,
        "hosts" => ["api.keyed.test"]
      }
    })

    ConsentFixtures.bind_key!(ctx, "catalyst:local.keyed", %{"KEYED_API_KEY" => "k-test"})
    assert states(ctx) == %{"keyed" => :ready}

    {:ok, %{revoked: [_]}} = Sanctum.Consent.revoke_source(ctx, "catalyst:local.keyed")
    assert states(ctx) == %{"keyed" => :needs_key}
  end

  # The removal at a test's end: a root it cannot remove fails the test with
  # what the root held. A folder whose entries cannot be removed stands in
  # for one written to while it is removed.
  test "a storage root that cannot be removed fails with what it held, and when" do
    root =
      Path.join(System.tmp_dir!(), "models_unremovable_#{System.unique_integer([:positive])}")

    locked = Path.join(root, "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "late.bin"), "12345")
    File.chmod!(locked, 0o500)

    on_exit(fn ->
      File.chmod(locked, 0o700)
      File.rm_rf(root)
    end)

    error = assert_raise ExUnit.AssertionError, fn -> remove_root!(root) end

    assert error.message =~ ~r/^#{Regex.escape(root)} was not removed at \d{4}-\d\d-\d\dT[^ ]+: /
    assert error.message =~ "  locked: directory, "
    assert error.message =~ ~r/  locked\/late\.bin: regular, 5 bytes, modified \d{4}-/
  end

  # A catalyst that speaks `model/chat@1` with `needs`, published under
  # the test's storage root.
  defp chat_brain!(ctx, name, needs) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        manifest:
          Jason.encode!(%{
            "contracts" => [Prima.Model.chat_contract()],
            "needs" => needs,
            "caps" => %{
              "egress" => %{"domains" => Enum.flat_map(Map.values(needs), &(&1["hosts"] || []))}
            }
          })
      })
  end

  # The state each of the test's own brains reads in Aqua's setup.
  defp states(ctx) do
    {:ok, providers} = Aqua.providers(ctx)

    for %{provider: p, state: state} <- providers,
        p in ["open", "keyed"],
        into: %{},
        do: {p, state}
  end

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
    on_exit(fn -> remove_root!(test_path) end)
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    fills_end_first!()
    %{Sanctum.TestContext.local() | origin: :interactive}
  end

  # The test's athanor is not filled, so a read of it starts its fill in
  # the background, which lays the athanor's folders under whatever root
  # `:arca, :base_path` names as it runs. Registered last, this runs first
  # at the test's end: the fills end while the root is still the test's,
  # before the root is restored and removed.
  defp fills_end_first! do
    test = self()
    on_exit(fn -> Cyfr.Test.Fill.ended!(test) end)
  end

  # A root that is not removed fails the test, naming what it held at that
  # moment and when. `File.rm_rf/1` passes over a child it cannot remove and
  # reports only the root's own removal, so "file already exists" means
  # something was left or written while the root was removed; the listing
  # says what, so the run that meets it names the writer.
  defp remove_root!(root) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        at = DateTime.utc_now()

        flunk("""
        #{root} was not removed at #{DateTime.to_iso8601(at)}: #{:file.format_error(reason)} at #{path}. It held:
        #{held(root)}
        """)
    end
  end

  # Each path under the root, with its type, size and modification time.
  defp held(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map_join("\n", fn path ->
      name = Path.relative_to(path, root)

      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
          "  #{name}: #{type}, #{size} bytes, modified #{DateTime.to_iso8601(DateTime.from_unix!(mtime))}"

        {:error, reason} ->
          "  #{name}: #{:file.format_error(reason)}"
      end
    end)
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

    fills_end_first!()

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
