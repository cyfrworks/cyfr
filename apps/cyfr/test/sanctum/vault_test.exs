# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultTest do
  use ExUnit.Case, async: false

  # What a dispense is made for, as an attempt names it. These resources
  # carry no binding key, so no binding lifetime is read for them.
  @dispense %{root_execution_id: "exec_reader_test", profile_id: nil, consent_id: nil}

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Vault
  alias Sanctum.VaultReader

  # Where the fixtures' entries may go. The cases here read what they
  # entered, so their entries are disclosed.
  @destination %{"hosts" => ["db.example"], "scheme" => "https"}
  @destination_text ~s({"hosts":["db.example"],"scheme":"https"})

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  defp create!(ctx, over \\ %{}) do
    params =
      Map.merge(
        %{
          name: "supabase-#{System.unique_integer([:positive])}",
          kind: "api_key",
          fields: %{"url" => "https://db.example", "anon_key" => "anon"},
          destination: @destination,
          disclose: true
        },
        over
      )

    {:ok, view} = create(ctx, params)
    view
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # An OAuth entry of a provider with a preset, holding no fields.
  defp oauth_params(over) do
    Map.merge(
      %{
        name: "oauth-#{System.unique_integer([:positive])}",
        kind: "oauth",
        provider_hint: "google",
        fields: %{},
        oauth_scopes: ["gmail.readonly"],
        destination: %{"hosts" => ["gmail.googleapis.com"]},
        disclose: true
      },
      over
    )
  end

  defp row!(ctx, id) do
    {:ok, row} = Arca.VaultStorage.get(actor(ctx), id)
    row
  end

  defp payload!(ctx, id) do
    row = row!(ctx, id)
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, row.provider_hint)
    {:ok, plaintext} = Sanctum.Cipher.decrypt(row.sealed_payload, aad)
    {:ok, payload} = Sanctum.Vault.Payload.decode(plaintext)
    payload
  end

  # A credential entered, or rotated, as a person enters it: under the
  # confirmation they proved (`Sanctum.TestContext.confirmed/3`), for
  # exactly the change the vault decides, the entry named as it names it.
  defp create(ctx, params),
    do: Vault.create(entering(ctx, "vault.create", params, params[:name]), params)

  defp rotate(ctx, %{id: id} = params) do
    case Arca.VaultStorage.get(actor(ctx), id) do
      {:ok, %{name: name}} -> Vault.rotate(entering(ctx, "vault.rotate", params, name), params)
      _missing -> Vault.rotate(ctx, params)
    end
  end

  defp entering(ctx, operation, params, name) do
    Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
      operation: operation,
      arguments: params,
      resource: name
    })
  end

  # A rebind its person confirmed: asked, proven and repeated as Prism
  # repeats a change once its person confirmed it
  # (`Sanctum.TestContext.confirming/2`).
  defp rebind_confirmed(ctx, params),
    do: Sanctum.TestContext.confirming(ctx, &Vault.rebind(&1, params))

  # The pending confirmation whose secret `id` a signal answered.
  defp confirmation!(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(actor(ctx), Prima.Confirmation.ref(id))
    row
  end

  defp resource_for(ctx, id) do
    {:ok, entry} = Arca.VaultStorage.get(actor(ctx), id)
    {:ok, digest} = VaultReader.binding_digest(entry)
    fields = entry.field_names |> Jason.decode!() |> Map.new(&{&1, &1})
    %{entry_id: id, binding_digest: digest, projection: %{fields: fields, scopes: []}}
  end

  # A profile of its own consumer, so a case may mint one per entry.
  defp mint_profile_with_ref(ctx, entry_id, binding_digest) do
    consumer = "formula:local.consumer-#{System.unique_integer([:positive])}"

    {:ok, profile} =
      Arca.Test.Writers.put_profile(%{
        athanor_id: ctx.athanor_id,
        source_ref: consumer,
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _consent} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: ctx.athanor_id,
          profile_id: profile.id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.Digest.sha256("{}"),
          resolved_policy: "{}",
          activation: "{}",
          admitted_origins: [:interactive],
          granted_by: "test",
          granted_via: "bootstrap"
        },
        [
          %{
            binding_key: consumer <> "|@ingress|default",
            scope: "athanor",
            vault_entry_id: entry_id,
            binding_digest: binding_digest
          }
        ],
        nil
      )

    profile
  end

  # A telemetry handler on every repo statement: the test process runs the
  # race's `act` once, at the first statement its `point` names, after that
  # statement ran.
  @doc false
  def race(_event, _measurements, metadata, %{test: test, point: point, act: act}) do
    if self() == test and Process.get(:rebind_race) == :armed and point.(metadata) do
      Process.put(:rebind_race, :fired)
      act.()
    end

    :ok
  end

  defp race!(point, act) do
    handler = "vault-rebind-race-#{System.unique_integer([:positive])}"
    config = %{test: self(), point: point, act: act}
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.race/4, config)
    on_exit(fn -> :telemetry.detach(handler) end)
    Process.put(:rebind_race, :armed)
  end

  describe "authorization class" do
    test "no vault mutation is reachable from an api_key surface", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, {:surface_not_permitted, :api_key}} =
               Vault.create(key_ctx, %{name: "x", kind: "api_key"})

      assert {:error, {:surface_not_permitted, :api_key}} = Vault.rename(key_ctx, "vlt_x", "y")

      assert {:error, {:surface_not_permitted, :api_key}} =
               Vault.rotate(key_ctx, %{id: "vlt_x", fields: %{}, expected_payload_rev: 0})

      assert {:error, {:surface_not_permitted, :api_key}} = Vault.rebind(key_ctx, %{id: "vlt_x"})
      assert {:error, {:surface_not_permitted, :api_key}} = Vault.revoke(key_ctx, "vlt_x")
      assert {:error, {:surface_not_permitted, :api_key}} = Vault.delete(key_ctx, "vlt_x")
    end

    test "a guest-planed context is refused before anything else", %{ctx: ctx} do
      guest = Sanctum.Context.enter_guest(ctx)

      assert {:error, :guest_plane} = Vault.create(guest, %{name: "x", kind: "api_key"})
      assert {:error, :guest_plane} = Vault.revoke(guest, "vlt_x")
    end
  end

  describe "a credential entry is a sensitive change" do
    setup %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      %{person: person}
    end

    test "entered from a session with no proof, it answers the signal and seals nothing",
         %{person: person} do
      params = %{
        name: "unproven",
        kind: "api_key",
        fields: %{"KEY" => "sk-unproven"},
        destination: @destination
      }

      assert {:error, {:confirmation_required, %{id: id, operation: "vault.create"}}} =
               Vault.create(person, params)

      assert is_binary(id)
      {:ok, listed} = Vault.list(person)
      refute Enum.any?(listed, &(&1.name == "unproven"))
    end

    test "rotated from a session with no proof, the material stays", %{person: person} do
      view = create!(person, %{fields: %{"key" => "before"}})
      params = %{id: view.id, fields: %{"key" => "after"}, expected_payload_rev: 0}

      assert {:error, {:confirmation_required, %{operation: "vault.rotate"}}} =
               Vault.rotate(person, params)

      assert {:ok, %{"key" => "before"}} =
               VaultReader.fetch(person, resource_for(person, view.id), @dispense)
    end

    test "a grant started, or client credentials stored, from a session with no proof ask first",
         %{person: person} do
      assert {:error, {:confirmation_required, %{operation: "vault.authorize"}}} =
               Sanctum.Vault.OAuthGrant.authorize_url(person, %{
                 name: "Mail",
                 provider: "google",
                 scopes: ["mail"],
                 destination: %{"hosts" => ["gmail.googleapis.com"]}
               })

      assert {:error, {:confirmation_required, %{operation: "oauth.set_client"}}} =
               Sanctum.ProviderCredentials.put(person, "google", "cid", "csec")

      assert {:ok, []} = Sanctum.ProviderCredentials.list(person)
    end

    test "a confirmation enters its one credential: another name or other material asks again",
         %{person: person} do
      params = %{
        name: "one",
        kind: "api_key",
        fields: %{"KEY" => "sk-one"},
        destination: @destination
      }

      confirmed = entering(person, "vault.create", params, "one")

      other = %{params | fields: %{"KEY" => "sk-two"}}
      assert {:error, {:confirmation_required, _}} = Vault.create(confirmed, other)
      assert {:ok, %{name: "one"}} = Vault.create(confirmed, params)
    end

    test "renaming, revoking and deleting need the session alone", %{person: person} do
      view = create!(person)

      assert :ok = Vault.rename(person, view.id, "renamed-by-session")
      assert {:ok, _} = Vault.revoke(person, view.id)
      assert :ok = Vault.delete(person, view.id)
    end
  end

  describe "create + list" do
    test "creates sealed material and lists metadata only", %{ctx: ctx} do
      view = create!(ctx, %{name: "my-supabase"})

      assert view.name == "my-supabase"
      assert view.status == "active"
      assert view.field_names == ["anon_key", "url"]
      assert view.payload_rev == 0
      refute Map.has_key?(view, :sealed_payload)

      {:ok, listed} = Vault.list(ctx)
      assert Enum.any?(listed, &(&1.id == view.id))

      # The material actually resolves through the reader.
      assert {:ok, %{"url" => "https://db.example", "anon_key" => "anon"}} =
               VaultReader.fetch(ctx, resource_for(ctx, view.id), @dispense)
    end

    test "a living name cannot be reused", %{ctx: ctx} do
      create!(ctx, %{name: "taken"})

      assert {:error, :name_taken} =
               create(ctx, %{name: "taken", kind: "api_key", destination: @destination})
    end

    test "an entry names its destination: none, or one off the grammar, is refused before anything is asked",
         %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)

      # Refused for its shape before any confirmation: nothing to confirm.
      assert {:error, :destination_required} =
               Vault.create(person, %{name: "nowhere", kind: "api_key", fields: %{"K" => "v"}})

      for destination <- [
            %{"hosts" => []},
            %{"hosts" => ["*"]},
            %{"hosts" => ["https://api.example.com"]},
            %{"hosts" => ["api.example.com"], "scheme" => "ftp"},
            %{"hosts" => ["api.example.com"], "paths" => ["v1"]},
            %{"hosts" => ["api.example.com"], "port" => 70_000},
            "api.example.com"
          ] do
        assert {:error, {:invalid_destination, _}} =
                 Vault.create(person, %{
                   name: "nowhere",
                   kind: "api_key",
                   fields: %{"K" => "v"},
                   destination: destination
                 })
      end

      assert {:error, :invalid_disclose} =
               Vault.create(person, %{
                 name: "nowhere",
                 kind: "api_key",
                 destination: @destination,
                 disclose: "yes"
               })

      assert {:ok, listed} = Vault.list(person)
      refute Enum.any?(listed, &(&1.name == "nowhere"))
    end

    test "an entry is attach-only unless created with disclose: true, and says where it goes",
         %{ctx: ctx} do
      {:ok, attached} =
        create(ctx, %{
          name: "attached",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: @destination
        })

      assert attached.attach_only == true
      assert attached.destination == @destination

      disclosed = create!(ctx, %{name: "disclosed"})
      assert disclosed.attach_only == false

      assert row!(ctx, attached.id).destination == @destination_text
      assert row!(ctx, attached.id).attach_only == true

      # The binding digest covers both: the same entry otherwise differs.
      {:ok, a} = VaultReader.binding_digest(row!(ctx, attached.id))
      {:ok, d} = VaultReader.binding_digest(%{row!(ctx, attached.id) | attach_only: false})
      refute a == d
    end

    test "unknown kinds are refused", %{ctx: ctx} do
      assert {:error, {:invalid_kind, _}} = Vault.create(ctx, %{name: "x", kind: "wand"})
    end
  end

  describe "what an external server definition may name, read from metadata alone" do
    test "a header's entry is one whose destination admits a POST to the server's URL",
         %{ctx: ctx} do
      exact = create!(ctx, %{destination: %{"hosts" => ["api.openai.com"], "paths" => ["/v1"]}})
      wild = create!(ctx, %{destination: %{"hosts" => ["*.example.com"]}})
      get_only = create!(ctx, %{destination: %{"hosts" => ["db.example"], "methods" => ["GET"]}})

      assert Vault.destination_matches?(ctx, exact.name, "https://api.openai.com/v1/mcp")
      # Another host, the host outside the entry's paths, and another scheme.
      refute Vault.destination_matches?(ctx, exact.name, "https://evil.example/mcp")
      refute Vault.destination_matches?(ctx, exact.name, "https://api.openai.com/v2/mcp")
      refute Vault.destination_matches?(ctx, exact.name, "http://api.openai.com/v1/mcp")

      # A wildcard host admits a name below it, never the name itself.
      assert Vault.destination_matches?(ctx, wild.name, "https://mcp.example.com/mcp")
      refute Vault.destination_matches?(ctx, wild.name, "https://example.com/mcp")

      # Streamable HTTP posts every request: an entry bound to GET is not sent.
      refute Vault.destination_matches?(ctx, get_only.name, "https://db.example/mcp")

      # Nothing was unsealed, so no use was recorded.
      for entry <- [exact, wild, get_only], do: assert(row!(ctx, entry.id).last_used_at == nil)
    end

    test "a missing, inactive or foreign entry covers no URL", %{ctx: ctx} do
      url = "https://db.example/mcp"
      revoked = create!(ctx)
      {:ok, _} = Vault.revoke(ctx, revoked.id)
      living = create!(ctx)

      refute Vault.destination_matches?(ctx, "absent", url)
      refute Vault.destination_matches?(ctx, revoked.name, url)
      refute Vault.destination_matches?(%{ctx | athanor_id: "ath_other"}, living.name, url)
      assert Vault.destination_matches?(ctx, living.name, url)
    end

    test "a rebind moves where the entry may be sent", %{ctx: ctx} do
      entry = create!(ctx)
      url = "https://db.example/mcp"
      assert Vault.destination_matches?(ctx, entry.name, url)

      {:ok, _} =
        rebind_confirmed(ctx, %{id: entry.id, destination: %{"hosts" => ["elsewhere.example"]}})

      refute Vault.destination_matches?(ctx, entry.name, url)
    end

    test "a backend's env entry is an active, disclosed one", %{ctx: ctx} do
      disclosed = create!(ctx)

      {:ok, attached} =
        create(ctx, %{
          name: "attached-#{System.unique_integer([:positive])}",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: @destination
        })

      revoked = create!(ctx)
      {:ok, _} = Vault.revoke(ctx, revoked.id)

      assert Vault.disclosed?(ctx, disclosed.name)
      refute Vault.disclosed?(ctx, attached.name)
      refute Vault.disclosed?(ctx, revoked.name)
      refute Vault.disclosed?(ctx, "absent")
      refute Vault.disclosed?(%{ctx | athanor_id: "ath_other"}, disclosed.name)

      # Disclosed by a rebind, the attach-only entry may be named.
      {:ok, _} = rebind_confirmed(ctx, %{id: attached.id, disclose: true})
      assert Vault.disclosed?(ctx, attached.name)

      for entry <- [disclosed, attached], do: assert(row!(ctx, entry.id).last_used_at == nil)
    end
  end

  describe "defaults" do
    test "the first entry of a provider is its default, and a second is not", %{ctx: ctx} do
      first = create!(ctx, %{provider_hint: "openai.com"})
      _second = create!(ctx, %{provider_hint: "openai.com"})
      other = create!(ctx, %{provider_hint: "anthropic.com"})

      # An entry naming no provider is no provider's default.
      _unnamed = create!(ctx)

      assert {:ok, defaults} = Vault.defaults(ctx)

      assert defaults == %{
               "anthropic.com" => %{vault_entry_id: other.id},
               "openai.com" => %{vault_entry_id: first.id}
             }
    end

    test "a tombstoned default is gone, and no other entry takes its place", %{ctx: ctx} do
      first = create!(ctx, %{provider_hint: "openai.com"})
      _second = create!(ctx, %{provider_hint: "openai.com"})
      kept = create!(ctx, %{provider_hint: "anthropic.com"})

      assert :ok = Vault.delete(ctx, first.id)

      assert {:ok, %{"anthropic.com" => %{vault_entry_id: kept.id}}} == Vault.defaults(ctx)
    end

    test "another athanor's default is not answered", %{ctx: ctx} do
      theirs = Prima.Actor.in_athanor("ath_other")

      for hint <- ["openai.com", "anthropic.com"] do
        {:ok, _entry} =
          Arca.VaultStorage.put(theirs, %{
            name: "theirs-#{hint}",
            kind: "api_key",
            provider_hint: hint,
            sealed_payload: "sealed",
            destination: @destination_text
          })
      end

      assert {:ok, %{}} == Vault.defaults(ctx)

      mine = create!(ctx, %{provider_hint: "openai.com"})

      assert {:ok, %{"openai.com" => %{vault_entry_id: mine.id}}} == Vault.defaults(ctx)
      assert {:ok, [_, _]} = Arca.VaultDefaults.list(theirs)
    end

    test "a default naming an instance entry is answered as one", %{ctx: ctx} do
      {:ok, instance} =
        Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
          name: "instance-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          destination:
            ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
          sealed_payload: "sealed",
          binding_digest: "sha256:instance",
          audience: "everyone",
          created_by: "usr_admin"
        })

      {:ok, _default} =
        Arca.VaultDefaults.set(actor(ctx), "openai.com", %{instance_entry_id: instance.id})

      assert {:ok, %{"openai.com" => %{instance_entry_id: instance.id}}} == Vault.defaults(ctx)
    end

    test "set_default moves a provider's default to an entry of the athanor or an offered " <>
           "instance entry, and moves no consent",
         %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      first = create!(person, %{provider_hint: "openai.com"})
      second = create!(person, %{provider_hint: "openai.com"})

      assert {:ok, %{provider_hint: "openai.com", vault_entry_id: id}} =
               Vault.set_default(person, %{provider_hint: "openai.com", entry_id: second.id})

      assert id == second.id
      assert {:ok, %{"openai.com" => %{vault_entry_id: ^id}}} = Vault.defaults(person)

      {:ok, instance} =
        Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
          name: "instance-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          destination:
            ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
          sealed_payload: "sealed",
          binding_digest: "sha256:instance",
          audience: "everyone",
          created_by: "usr_admin"
        })

      assert {:ok, %{provider_hint: "openai.com", instance_entry_id: instance_id}} =
               Vault.set_default(person, %{
                 provider_hint: "openai.com",
                 instance_entry_id: instance.id
               })

      assert instance_id == instance.id

      # A profile bound to the first entry stays bound to it.
      profile = mint_profile_with_ref(person, first.id, "sha256:bound")
      {:ok, head, _refs} = Arca.ConsentStorage.get_head(actor(person), profile.id)

      assert {:ok, _} =
               Vault.set_default(person, %{provider_hint: "openai.com", entry_id: first.id})

      {:ok, still, refs} = Arca.ConsentStorage.get_head(actor(person), profile.id)
      assert still.id == head.id
      assert [%{vault_entry_id: bound}] = refs
      assert bound == first.id
    end

    test "set_default refuses an entry of another provider, one not offered or not active, " <>
           "and a request naming neither or both",
         %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      anthropic = create!(person, %{provider_hint: "anthropic.com"})
      openai = create!(person, %{provider_hint: "openai.com"})

      assert {:error, {:provider_mismatch, "openai.com"}} =
               Vault.set_default(person, %{provider_hint: "openai.com", entry_id: anthropic.id})

      for params <- [
            %{provider_hint: "openai.com"},
            %{provider_hint: "openai.com", entry_id: openai.id, instance_entry_id: "ine_x"},
            %{provider_hint: "", entry_id: openai.id},
            %{entry_id: openai.id}
          ] do
        assert {:error, {:invalid_argument, _why}} = Vault.set_default(person, params),
               "#{inspect(params)} was accepted"
      end

      {:ok, listed} =
        Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
          name: "listed-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          destination:
            ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
          sealed_payload: "sealed",
          binding_digest: "sha256:listed",
          audience: "listed",
          created_by: "usr_admin"
        })

      assert {:error, :not_offered} =
               Vault.set_default(person, %{
                 provider_hint: "openai.com",
                 instance_entry_id: listed.id
               })

      {:ok, _} = Vault.revoke(person, openai.id)

      assert {:error, {:entry_unavailable, "revoked"}} =
               Vault.set_default(person, %{provider_hint: "openai.com", entry_id: openai.id})

      # The session alone: a scoped key cannot reach it.
      assert {:error, _not_interactive} =
               Vault.set_default(%{person | auth_method: :api_key}, %{
                 provider_hint: "anthropic.com",
                 entry_id: anthropic.id
               })

      assert {:ok, %{"anthropic.com" => %{vault_entry_id: kept}}} = Vault.defaults(person)
      assert kept == anthropic.id
    end
  end

  describe "rotate changes material without requiring re-consent" do
    test "replaces material under CAS; the binding digest does not move", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "old-material"}})
      resource = resource_for(ctx, view.id)

      assert {:ok, 1} =
               rotate(ctx, %{
                 id: view.id,
                 fields: %{"key" => "new-material"},
                 expected_payload_rev: 0
               })

      # The consent's copy of the binding digest still verifies — rotation
      # never forces a re-consent.
      assert {:ok, %{"key" => "new-material"}} = VaultReader.fetch(ctx, resource, @dispense)
      assert resource_for(ctx, view.id).binding_digest == resource.binding_digest
    end

    test "a stale expected_payload_rev loses the race", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})

      assert {:error, :payload_conflict} =
               rotate(ctx, %{id: view.id, fields: %{"key" => "x"}, expected_payload_rev: 7})
    end

    test "a schema change is not a rotation", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})

      assert {:error, :schema_change_requires_rebind} =
               rotate(ctx, %{
                 id: view.id,
                 fields: %{"other" => "v"},
                 expected_payload_rev: 0
               })
    end

    test "rotating a needs_reauth entry reactivates it", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})
      :ok = Arca.VaultStorage.set_status(actor(ctx), view.id, "needs_reauth")

      assert {:ok, 1} =
               rotate(ctx, %{
                 id: view.id,
                 fields: %{"key" => "v2"},
                 expected_payload_rev: 0
               })

      {:ok, entry} = Arca.VaultStorage.get(actor(ctx), view.id)
      assert entry.status == "active"
    end

    test "a rotate that loses its compare-and-set leaves the entry whole", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "before"}})
      resource = resource_for(ctx, view.id)
      :ok = Arca.VaultStorage.set_status(actor(ctx), view.id, "needs_reauth")

      # The material write and the reactivation that goes with it are one
      # transaction: a lost race leaves neither, so the entry is still
      # readable at exactly the version it was readable at before.
      assert {:error, :payload_conflict} =
               rotate(ctx, %{
                 id: view.id,
                 fields: %{"key" => "after"},
                 expected_payload_rev: 7
               })

      {:ok, entry} = Arca.VaultStorage.get(actor(ctx), view.id)
      assert entry.status == "needs_reauth"
      assert entry.payload_rev == 0

      :ok = Arca.VaultStorage.set_status(actor(ctx), view.id, "active")
      assert {:ok, %{"key" => "before"}} = VaultReader.fetch(ctx, resource, @dispense)
    end
  end

  describe "rebind requires re-consent" do
    test "moves the derived digest and blocks affected head profiles", %{ctx: ctx} do
      view = create!(ctx)
      old_resource = resource_for(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, old_resource.binding_digest)

      assert {:ok, %{binding_digest: new_digest, affected: affected}} =
               rebind_confirmed(ctx, %{
                 id: view.id,
                 field_names: ["anon_key", "service_key", "url"]
               })

      assert new_digest != old_resource.binding_digest
      assert affected == [profile.id]

      # The old consent's digest no longer verifies.
      assert {:error, :binding_mismatch} = VaultReader.fetch(ctx, old_resource, @dispense)

      {:ok, reloaded} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile.id)
      assert reloaded.status == "needs_consent"
    end

    test "a binding moves only from the digest it was read at, and a rebind derives its digest " <>
           "from what landed",
         %{ctx: ctx} do
      view = create!(ctx)
      {:ok, entry} = Arca.VaultStorage.get(actor(ctx), view.id)
      assert is_binary(entry.binding_digest)

      assert {:error, :binding_moved} =
               Arca.VaultStorage.move_binding(
                 actor(ctx),
                 view.id,
                 "sha256:stale",
                 %{field_names: ~s(["x"])},
                 Vault.blocked_profile_status()
               )

      assert {:ok, %{binding_digest: first}} =
               rebind_confirmed(ctx, %{id: view.id, field_names: ["anon_key", "region", "url"]})

      assert {:ok, %{binding_digest: digest}} =
               rebind_confirmed(ctx, %{
                 id: view.id,
                 field_names: ["anon_key", "service_key", "url"]
               })

      {:ok, row} = Arca.VaultStorage.get(actor(ctx), view.id)
      assert digest != first
      assert row.field_names == ~s(["anon_key","service_key","url"])
      assert row.binding_digest == digest
      assert {:ok, ^digest} = VaultReader.binding_digest(row)
    end

    test "moving the destination or the disclosure is a rebind: the digest moves, dependents block",
         %{ctx: ctx} do
      view = create!(ctx)
      old_resource = resource_for(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, old_resource.binding_digest)

      assert {:ok, %{binding_digest: moved, affected: [affected]}} =
               Vault.rebind(ctx, %{
                 id: view.id,
                 destination: %{"hosts" => ["db.example"], "paths" => ["/rest/v1/"]}
               })

      assert affected == profile.id
      refute moved == old_resource.binding_digest

      assert row!(ctx, view.id).destination ==
               ~s({"hosts":["db.example"],"paths":["/rest/v1/"],"scheme":"https"})

      assert {:ok, %{binding_digest: attached}} =
               Vault.rebind(ctx, %{id: view.id, disclose: false})

      refute attached == moved
      assert row!(ctx, view.id).attach_only == true

      assert {:error, {:invalid_destination, _}} =
               Vault.rebind(ctx, %{id: view.id, destination: %{"hosts" => []}})

      assert {:error, :invalid_disclose} = Vault.rebind(ctx, %{id: view.id, disclose: "no"})
    end

    test "a rebind with no binding fields is refused", %{ctx: ctx} do
      view = create!(ctx)

      assert {:error, :no_binding_changes} = Vault.rebind(ctx, %{id: view.id})
    end

    test "rebind refuses changed OAuth endpoints before unsealing", %{ctx: ctx} do
      view = create!(ctx, oauth_params(%{oauth: %{"access_token" => "tok-live"}}))
      before = row!(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, before.binding_digest)

      elsewhere = %{
        "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url" => "https://elsewhere.example/token"
      }

      # Whatever else it names, a rebind naming endpoints changes nothing:
      # the endpoints a refresh token is sent to are fixed with the entry.
      for params <- [
            %{id: view.id, oauth_endpoints: elsewhere},
            %{id: view.id, oauth_endpoints: elsewhere, oauth_scopes: ["gmail.send"]},
            %{id: view.id, oauth_endpoints: nil}
          ] do
        assert {:error, :endpoints_immutable} = Vault.rebind(ctx, params)
      end

      after_row = row!(ctx, view.id)
      assert after_row.binding_digest == before.binding_digest
      assert {:ok, before.binding_digest} == VaultReader.binding_digest(after_row)
      assert after_row.oauth_endpoints == before.oauth_endpoints
      assert after_row.oauth_scopes == before.oauth_scopes
      assert after_row.payload_rev == before.payload_rev
      assert after_row.last_used_at == before.last_used_at

      {:ok, unblocked} = Arca.ProfileStorage.get(actor(ctx), profile.id)
      assert unblocked.status == "active"

      # Refused before the entry is read: an id that names nothing answers
      # the same refusal, not that nothing is there.
      assert {:error, :endpoints_immutable} =
               Vault.rebind(ctx, %{id: "vlt_nonexistent", oauth_endpoints: elsewhere})
    end

    test "an OAuth entry's scopes change only by re-authorization", %{ctx: ctx} do
      # The entry's token was granted for both scopes. Narrowing the column
      # alone would make one scope the whole grant, and the projection of
      # that one scope would then be served the token granted for both.
      view =
        create!(
          ctx,
          oauth_params(%{
            oauth: %{"access_token" => "tok-wide", "refresh_token" => "rt"},
            oauth_scopes: ["gmail.readonly", "gmail.send"]
          })
        )

      before = row!(ctx, view.id)

      assert {:error, :scopes_need_reauthorization} =
               Vault.rebind(ctx, %{id: view.id, oauth_scopes: ["gmail.readonly"]})

      after_row = row!(ctx, view.id)
      assert after_row.oauth_scopes == before.oauth_scopes
      assert after_row.binding_digest == before.binding_digest

      # So a consent naming the one scope is still a narrower projection of
      # the entry, refused, and never served the broad token.
      narrower = %{
        entry_id: view.id,
        binding_digest: after_row.binding_digest,
        projection: %{fields: %{}, scopes: ["gmail.readonly"]}
      }

      assert {:error, :scope_not_attenuable} =
               VaultReader.oauth_token(ctx, narrower, "google", @dispense)

      # Refused before the entry is read, and whatever else the rebind names.
      assert {:error, :scopes_need_reauthorization} =
               Vault.rebind(ctx, %{id: "vlt_nonexistent", oauth_scopes: ["gmail.readonly"]})

      assert {:error, :scopes_need_reauthorization} =
               Vault.rebind(ctx, %{id: view.id, oauth_scopes: nil, field_names: ["note"]})

      assert row!(ctx, view.id).field_names == before.field_names

      # The field schema still rebinds; a disclosed field it adds is the
      # person's to confirm.
      assert {:ok, %{binding_digest: moved}} =
               rebind_confirmed(ctx, %{id: view.id, field_names: ["note"]})

      assert moved != before.binding_digest
    end
  end

  describe "a widening rebind is its person's to confirm" do
    setup %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      %{person: person}
    end

    test "a rebind that widens where the material may go or what a component reads asks " <>
           "first, and moves nothing until confirmed",
         %{person: person} do
      narrow = %{"hosts" => ["api.db.example"], "methods" => ["GET"], "paths" => ["/v1"]}

      for {stored, params} <- [
            # Another host, and a host pattern over the stored host.
            {%{destination: narrow},
             %{destination: Map.put(narrow, "hosts", ["api.db.example", "other.example"])}},
            {%{destination: narrow}, %{destination: Map.put(narrow, "hosts", ["*.db.example"])}},
            # Another method, and every method.
            {%{destination: narrow}, %{destination: Map.put(narrow, "methods", ["GET", "POST"])}},
            {%{destination: narrow}, %{destination: Map.delete(narrow, "methods")}},
            # Another path prefix, a wider one, every path, and a sibling.
            {%{destination: narrow}, %{destination: Map.put(narrow, "paths", ["/v1", "/v2"])}},
            {%{destination: Map.put(narrow, "paths", ["/v1/models"])}, %{destination: narrow}},
            {%{destination: narrow}, %{destination: Map.delete(narrow, "paths")}},
            {%{destination: narrow}, %{destination: Map.put(narrow, "paths", ["/v1x"])}},
            # Another port, another scheme.
            {%{destination: narrow}, %{destination: Map.put(narrow, "port", 8443)}},
            {%{destination: narrow}, %{destination: Map.put(narrow, "scheme", "http")}},
            # Disclosure turned on, and a disclosed field added.
            {%{disclose: false}, %{disclose: true}},
            {%{}, %{field_names: ["anon_key", "service_key", "url"]}},
            {%{}, %{field_names: ["anon_key", "region"]}}
          ] do
        view = create!(person, stored)
        before = row!(person, view.id)
        profile = mint_profile_with_ref(person, view.id, before.binding_digest)

        assert {:error, {:confirmation_required, %{id: id, operation: "vault.rebind"}}} =
                 Vault.rebind(person, Map.put(params, :id, view.id)),
               inspect(params)

        assert confirmation!(person, id).state == "pending"
        assert row!(person, view.id) == before, inspect(params)

        assert {:ok, %{status: "active"}} =
                 Arca.ProfileStorage.get(actor(person), profile.id)
      end
    end

    test "a rebind that narrows the binding, or keeps what it admits, needs the session alone",
         %{person: person} do
      wide = %{"hosts" => ["db.example", "*.api.example"]}

      for {stored, params} <- [
            {%{destination: wide}, %{destination: %{"hosts" => ["db.example"]}}},
            {%{destination: wide}, %{destination: %{"hosts" => ["v1.api.example"]}}},
            {%{destination: wide}, %{destination: %{"hosts" => ["*.eu.api.example"]}}},
            {%{destination: wide}, %{destination: Map.put(wide, "methods", ["GET"])}},
            {%{destination: wide}, %{destination: Map.put(wide, "paths", ["/v1"])}},
            {%{destination: Map.put(wide, "paths", ["/v1"])},
             %{destination: Map.put(wide, "paths", ["/v1/models"])}},
            # The same admitted sets spelled out: the default port, every
            # method, the root path.
            {%{destination: wide},
             %{
               destination:
                 Map.merge(wide, %{
                   "port" => 443,
                   "methods" => Prima.Destination.methods(),
                   "paths" => ["/"]
                 })
             }},
            {%{}, %{disclose: false}},
            {%{}, %{field_names: ["url"]}},
            # An attach-only entry's field schema is read by no component.
            {%{disclose: false}, %{field_names: ["anon_key", "service_key", "url"]}}
          ] do
        view = create!(person, stored)
        before = row!(person, view.id)

        assert {:ok, %{binding_digest: digest}} =
                 Vault.rebind(person, Map.put(params, :id, view.id)),
               inspect(params)

        refute digest == before.binding_digest
        assert row!(person, view.id).binding_digest == digest
      end

      {:ok, open} = Arca.PendingConfirmations.list_open(actor(person), person.user_id)
      refute Enum.any?(open, &(&1.operation == "vault.rebind"))
    end

    test "disclosed fields are compared as sets: a repeated name is no new field",
         %{person: person} do
      view = create!(person, %{fields: %{"key" => "material", "url" => "https://db.example"}})
      assert view.field_names == ["key", "url"]

      # `url` dropped and `key` named twice: fewer fields, the session alone.
      assert {:ok, _} = Vault.rebind(person, %{id: view.id, field_names: ["key", "key"]})
      narrowed = row!(person, view.id)
      assert MapSet.new(Jason.decode!(narrowed.field_names)) == MapSet.new(["key"])

      # A name the entry does not disclose is growth, however often the
      # names it does disclose are repeated beside it.
      assert {:error, {:confirmation_required, %{operation: "vault.rebind"}}} =
               Vault.rebind(person, %{id: view.id, field_names: ["key", "key", "region"]})

      assert row!(person, view.id) == narrowed
    end

    test "a confirmed widening rebind moves the binding its person was shown, and nothing else",
         %{person: person} do
      view =
        create!(person, %{
          disclose: false,
          destination: %{"hosts" => ["db.example"], "paths" => ["/v1"]}
        })

      before = row!(person, view.id)
      profile = mint_profile_with_ref(person, view.id, before.binding_digest)

      params = %{
        id: view.id,
        destination: %{"hosts" => ["db.example", "files.example"], "methods" => ["GET"]},
        disclose: true,
        field_names: ["anon_key", "region", "url"]
      }

      assert {:error, {:confirmation_required, %{id: id}}} = Vault.rebind(person, params)

      record = confirmation!(person, id)
      assert {record.operation, record.action} == {"vault.rebind", "credential_entry"}
      preview = Jason.decode!(record.preview)
      assert preview["resource"] == view.name

      # The binding it moves to, every part a rebind moves, and what each
      # moved part was: the destination's admitted sets, the disclosure and
      # the field schema: no secret, and no material.
      assert preview["details"] == %{
               "scheme" => "https",
               "port" => "443",
               "hosts" => ["db.example", "files.example"],
               "hosts_before" => ["db.example"],
               "methods" => ["GET"],
               "methods_before" => Prima.Destination.methods(),
               "paths" => ["/"],
               "paths_before" => ["/v1"],
               "disclosed" => "yes",
               "disclosed_before" => "no",
               "field_names" => ["anon_key", "region", "url"],
               "field_names_before" => ["anon_key", "url"]
             }

      Sanctum.TestContext.prove!(person, id)

      assert {:ok, %{binding_digest: digest, affected: [affected]}} =
               Vault.rebind(%{person | confirmation_id: id}, params)

      assert affected == profile.id
      assert confirmation!(person, id).state == "consumed"

      # What moved is what the preview showed, and what it did not show did
      # not move: the provider, the OAuth endpoints and scopes, the
      # material.
      moved = row!(person, view.id)

      assert moved.destination ==
               ~s({"hosts":["db.example","files.example"],"methods":["GET"],"scheme":"https"})

      assert {moved.attach_only, moved.field_names, moved.binding_digest} ==
               {false, ~s(["anon_key","region","url"]), digest}

      for column <- [
            :provider_hint,
            :oauth_endpoints,
            :oauth_scopes,
            :name,
            :kind,
            :status,
            :sealed_payload,
            :payload_rev
          ] do
        assert Map.fetch!(moved, column) == Map.fetch!(before, column), inspect(column)
      end

      assert Vault.rebind_details(before, moved) == preview["details"]
      assert {:ok, ^digest} = VaultReader.binding_digest(moved)

      {:ok, blocked} = Arca.ProfileStorage.get(actor(person), profile.id)
      assert blocked.status == "needs_consent"
    end

    test "a proof moves its one binding: another entry, another destination, or a binding " <>
           "that moved under it asks again",
         %{person: person} do
      view = create!(person)
      other = create!(person)
      wider = %{id: view.id, destination: %{"hosts" => ["db.example", "files.example"]}}

      assert {:error, {:confirmation_required, %{id: id}}} = Vault.rebind(person, wider)
      Sanctum.TestContext.prove!(person, id)
      proven = %{person | confirmation_id: id}

      for params <- [
            %{wider | id: other.id},
            %{wider | destination: %{"hosts" => ["db.example", "logs.example"]}},
            Map.put(wider, :disclose, false)
          ] do
        before = row!(person, params.id)

        assert {:error, {:confirmation_required, %{id: asked}}} = Vault.rebind(proven, params),
               inspect(params)

        refute asked == id
        assert row!(person, params.id) == before
      end

      # The binding moves before the proof is spent (a narrowing, the
      # session alone): the proof was given over the binding that was, and
      # is not spent on the one that is.
      assert {:ok, _} = Vault.rebind(person, %{id: view.id, field_names: ["url"]})
      moved = row!(person, view.id)

      assert {:error, {:confirmation_required, %{id: asked}}} = Vault.rebind(proven, wider)
      refute asked == id
      assert row!(person, view.id) == moved
      assert confirmation!(person, id).state == "confirmed"
    end

    test "a write that lost its compare-and-set and rolled back is retried, and spends the one " <>
           "proof the lost write did not",
         %{person: person} do
      view = create!(person)
      params = %{id: view.id, destination: %{"hosts" => ["db.example", "files.example"]}}

      assert {:error, {:confirmation_required, %{id: id}}} = Vault.rebind(person, params)
      Sanctum.TestContext.prove!(person, id)

      # In the binding move's transaction, once the proof is consumed and
      # before the compare-and-set, the row's digest is moved in that same
      # transaction: the compare-and-set loses, and its rollback takes the
      # consumption and the move back together, so the retry reads the
      # binding the proof was given over and finds the proof unspent.
      race!(
        fn %{source: source, query: query} ->
          source == "pending_confirmations" and String.starts_with?(query, "UPDATE")
        end,
        fn ->
          {1, _} =
            Arca.Repo.update_all(from(v in Arca.Schemas.VaultEntry, where: v.id == ^view.id),
              set: [binding_digest: "sha256:moved-in-the-lost-write"]
            )
        end
      )

      assert {:ok, %{binding_digest: digest}} =
               Vault.rebind(%{person | confirmation_id: id}, params)

      assert Process.get(:rebind_race) == :fired
      assert row!(person, view.id).binding_digest == digest
      assert confirmation!(person, id).state == "consumed"
    end

    test "a binding another rebind moved before the compare-and-set refuses the proof and " <>
           "asks again, spending nothing",
         %{person: person} do
      view = create!(person)
      params = %{id: view.id, destination: %{"hosts" => ["db.example", "files.example"]}}

      assert {:error, {:confirmation_required, %{id: id}}} = Vault.rebind(person, params)
      Sanctum.TestContext.prove!(person, id)

      # Just after the rebind read the entry, another rebind of it commits.
      race!(
        fn %{source: source, query: query} ->
          source == "vault_entries" and String.starts_with?(query, "SELECT")
        end,
        fn -> {:ok, _} = Vault.rebind(person, %{id: view.id, field_names: ["url"]}) end
      )

      assert {:error, {:confirmation_required, %{id: asked}}} =
               Vault.rebind(%{person | confirmation_id: id}, params)

      assert Process.get(:rebind_race) == :fired
      refute asked == id

      moved = row!(person, view.id)
      assert moved.field_names == ~s(["url"])
      assert moved.destination == @destination_text
      assert confirmation!(person, id).state == "confirmed"
    end
  end

  describe "an OAuth entry's endpoints are fixed when it is created" do
    test "a provider with a preset takes the preset's endpoints, and its token dispenses",
         %{ctx: ctx} do
      view = create!(ctx, oauth_params(%{oauth: %{"access_token" => "tok-live"}}))
      %{endpoints: preset} = Sanctum.Vault.OAuth.preset("google")

      assert Jason.decode!(row!(ctx, view.id).oauth_endpoints) == preset

      {:ok, entry} = Arca.VaultStorage.get(actor(ctx), view.id)
      {:ok, digest} = VaultReader.binding_digest(entry)

      resource = %{
        entry_id: view.id,
        binding_digest: digest,
        projection: %{fields: %{}, scopes: ["gmail.readonly"]}
      }

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google", @dispense)
    end

    test "a provider with a preset and endpoints of its own, or one with neither, is refused",
         %{ctx: ctx} do
      given = %{
        "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url" => "https://attacker.example/token"
      }

      assert {:error, :endpoints_preset_conflict} =
               create(ctx, oauth_params(%{name: "conflict", oauth_endpoints: given}))

      assert {:error, :endpoints_required} =
               create(ctx, oauth_params(%{name: "neither", provider_hint: "acme"}))

      {:ok, listed} = Vault.list(ctx)
      refute Enum.any?(listed, &(&1.name in ["conflict", "neither"]))
    end

    test "an OAuth entry names its provider, whatever endpoints it names", %{ctx: ctx} do
      acme = %{
        "authorize_url" => "https://acme.example/authorize",
        "token_url" => "https://acme.example/token"
      }

      for params <- [
            oauth_params(%{name: "no-hint", provider_hint: "", oauth_endpoints: acme}),
            oauth_params(%{name: "no-hint", oauth_endpoints: acme}) |> Map.delete(:provider_hint),
            oauth_params(%{name: "no-hint", provider_hint: ""})
          ] do
        assert {:error, :provider_required} = create(ctx, params)
      end

      {:ok, listed} = Vault.list(ctx)
      refute Enum.any?(listed, &(&1.name == "no-hint"))
    end

    test "a provider without a preset names endpoints held to the endpoint rule", %{ctx: ctx} do
      acme = %{
        "authorize_url" => "https://acme.example/authorize",
        "token_url" => "https://acme.example/token",
        "auth_style" => "header",
        "extra_params" => %{"audience" => "acme-api"},
        "provider" => "acme"
      }

      view = create!(ctx, oauth_params(%{provider_hint: "acme", oauth_endpoints: acme}))

      # Stored as the endpoint keys alone.
      assert Jason.decode!(row!(ctx, view.id).oauth_endpoints) == Map.delete(acme, "provider")

      plaintext = %{acme | "token_url" => "http://acme.example/token"}
      steering = put_in(acme, ["extra_params", "state"], "attacker-chosen")
      partial = Map.delete(acme, "authorize_url")

      for {endpoints, refusal} <- [
            {plaintext, :endpoints_must_use_https},
            {steering, {:reserved_extra_param, "state"}},
            {partial, :endpoints_required}
          ] do
        assert {:error, ^refusal} =
                 create(
                   ctx,
                   oauth_params(%{
                     name: "acme-bad",
                     provider_hint: "acme",
                     oauth_endpoints: endpoints
                   })
                 )
      end
    end

    test "another kind stores no endpoints, whatever it is given", %{ctx: ctx} do
      view = create!(ctx, %{oauth_endpoints: %{"token_url" => "https://other.example/token"}})

      assert row!(ctx, view.id).oauth_endpoints == nil
    end

    test "the refusals are said in their own words, never as an unavailable vault",
         %{ctx: ctx} do
      for {args, code} <- [
            {%{"provider_hint" => "google", "oauth_endpoints" => %{"token_url" => "https://x"}},
             "endpoints_preset_conflict"},
            {%{"provider_hint" => "acme"}, "endpoints_required"},
            {%{
               "provider_hint" => "acme",
               "oauth_endpoints" => %{
                 "authorize_url" => "http://acme.example/a",
                 "token_url" => "http://acme.example/t"
               }
             }, "endpoints_must_use_https"},
            {%{
               "provider_hint" => "acme",
               "oauth_endpoints" => %{
                 "authorize_url" => "https://acme.example/a",
                 "token_url" => "https://acme.example/t",
                 "extra_params" => %{"scope" => "everything"}
               }
             }, "reserved_extra_param"},
            {%{
               "oauth_endpoints" => %{
                 "authorize_url" => "https://acme.example/a",
                 "token_url" => "https://acme.example/t"
               }
             }, "provider_required"}
          ] do
        # Refused for its own shape before any confirmation is asked.
        call =
          Map.merge(%{"action" => "create", "name" => "wire-#{code}", "kind" => "oauth"}, args)

        answer = Sanctum.Providers.Vault.handle(ctx, call)

        assert {:error, message} = answer
        assert is_binary(message) and String.starts_with?(message, code <> ": "), inspect(answer)
      end

      view = create!(ctx, oauth_params(%{oauth: %{"access_token" => "t"}}))

      assert {:error, "endpoints_immutable: " <> _} =
               Sanctum.Providers.Vault.handle(ctx, %{
                 "action" => "rebind",
                 "id" => view.id,
                 "oauth_endpoints" => %{"token_url" => "https://elsewhere.example/token"}
               })

      assert {:error, "scopes_need_reauthorization: " <> _} =
               Sanctum.Providers.Vault.handle(ctx, %{
                 "action" => "rebind",
                 "id" => view.id,
                 "oauth_scopes" => ["gmail.send"]
               })
    end
  end

  describe "an OAuth entry's bundle across a rotate" do
    test "a rotate without a bundle keeps the entry's; one with a bundle replaces it",
         %{ctx: ctx} do
      held = %{"access_token" => "tok-live", "refresh_token" => "rt"}

      view = create!(ctx, oauth_params(%{fields: %{"note" => "n"}, oauth: held}))

      assert {:ok, 1} =
               rotate(ctx, %{id: view.id, fields: %{"note" => "n2"}, expected_payload_rev: 0})

      assert %{"fields" => %{"note" => "n2"}, "oauth" => ^held} = payload!(ctx, view.id)

      regranted = %{"access_token" => "tok-regranted", "refresh_token" => "rt-2"}

      assert {:ok, 2} =
               rotate(ctx, %{
                 id: view.id,
                 fields: %{"note" => "n2"},
                 oauth: regranted,
                 expected_payload_rev: 1
               })

      assert %{"oauth" => ^regranted} = payload!(ctx, view.id)
    end
  end

  describe "revoke + delete" do
    test "revoke reports affected head profiles; the reader refuses next retrieval",
         %{ctx: ctx} do
      view = create!(ctx)
      resource = resource_for(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, resource.binding_digest)

      assert {:ok, %{affected: [profile_id]}} = Vault.revoke(ctx, view.id)
      assert profile_id == profile.id

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultReader.fetch(ctx, resource, @dispense)
    end

    test "delete tombstones, erases material, and frees the name", %{ctx: ctx} do
      view = create!(ctx, %{name: "reusable"})

      assert :ok = Vault.delete(ctx, view.id)

      {:ok, row} = Arca.VaultStorage.get(actor(ctx), view.id)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil

      # The living-name unique index ignores tombstones.
      assert {:ok, _} =
               create(ctx, %{name: "reusable", kind: "api_key", destination: @destination})
    end
  end

  describe "broadcasts" do
    test "every mutation announces itself on the tenant vault topic", %{ctx: ctx} do
      Cyfr.Bus.subscribe(
        Sanctum.Context.actor(ctx),
        Cyfr.Bus.vault_changed(Sanctum.Context.actor(ctx))
      )

      view = create!(ctx)
      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :create}

      {:ok, _} =
        rotate(ctx, %{id: view.id, fields: view_fields(ctx, view), expected_payload_rev: 0})

      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :rotate}

      :ok = Vault.rename(ctx, view.id, "renamed")
      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :rename}

      {:ok, _} = Vault.revoke(ctx, view.id)
      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :revoke}
    end

    test "every global signal names its entry, and a rename names the name it vacated too", %{
      ctx: ctx
    } do
      # External MCP servers hold header templates that resolve an entry by
      # NAME at request time, so the reconciler matches servers by the names
      # a signal carries — a deleted row can no longer be read for its name,
      # and a template may still spell the name a rename vacated.
      Cyfr.Bus.subscribe_global(Cyfr.Bus.vault_changed_global())

      view = create!(ctx)
      original_name = view.name
      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :create, name: ^original_name}

      :ok = Vault.rename(ctx, view.id, "moved")

      assert_receive %Cyfr.Bus.VaultEntryChanged{
        kind: :rename,
        name: "moved",
        old_name: ^original_name
      }

      :ok = Vault.delete(ctx, view.id)
      assert_receive %Cyfr.Bus.VaultEntryChanged{kind: :delete, name: "moved"}
    end

    defp view_fields(_ctx, view) do
      Map.new(view.field_names, fn name -> {name, "rotated"} end)
    end
  end
end
