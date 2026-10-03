# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultReaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Ecto.Query

  alias Sanctum.CipherAAD
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # Where the material may go. The cases read what they minted, so an
  # entry here is disclosed unless the case says `attach_only: true`.
  @destination ~s({"hosts":["api.example.com"],"scheme":"https"})

  defp mint_material_entry(ctx, fields, over \\ %{}) do
    id = Prima.UUID7.generate_id("vlt")
    hint = Map.get(over, :provider_hint, "")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, hint)

    {:ok, json} = Payload.encode_material(fields, Map.get(over, :oauth))
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    attrs = %{
      id: id,
      name: Map.get(over, :name, "entry-#{id}"),
      provider_hint: hint,
      kind: Map.get(over, :kind, "api_key"),
      field_names: Jason.encode!(Map.keys(fields) |> Enum.sort()),
      oauth_endpoints: Map.get(over, :oauth_endpoints),
      oauth_scopes: Map.get(over, :oauth_scopes),
      destination: @destination,
      attach_only: Map.get(over, :attach_only, false),
      status: Map.get(over, :status, "active"),
      sealed_payload: sealed
    }

    {:ok, entry} = Arca.VaultStorage.put(actor(ctx), attrs)
    {:ok, digest} = VaultReader.binding_digest(entry)

    # The edge a consent writes: its projection names the fields it reads
    # and, for an OAuth grant, the scopes the entry was authorized for.
    scopes = if json = Map.get(over, :oauth_scopes), do: Jason.decode!(json), else: []
    projection = %{fields: fields |> Map.keys() |> Enum.sort(), scopes: Enum.sort(scopes)}
    {entry, %{entry_id: entry.id, binding_digest: digest, projection: projection}}
  end

  defp last_used_at(ctx, entry) do
    {:ok, row} = Arca.VaultStorage.get(actor(ctx), entry.id)
    row.last_used_at
  end

  describe "fetch/2 — material" do
    test "projects the sealed fields; nothing outside the projection leaves", %{ctx: ctx} do
      fields = %{"url" => "https://db.example", "anon_key" => "anon", "service_key" => "SECRET"}
      {_entry, resource} = mint_material_entry(ctx, fields)
      resource = Map.put(resource, :projection, %{fields: ["url", "anon_key"], scopes: []})

      assert {:ok, resolved} = VaultReader.fetch(ctx, resource)
      assert resolved == %{"url" => "https://db.example", "anon_key" => "anon"}
      refute Map.has_key?(resolved, "service_key")
    end

    test "an edge whose projection names no fields is corrupt and dispenses nothing",
         %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"a" => "sealed-a", "b" => "sealed-b"})
      before = last_used_at(ctx, entry)

      # An edge stored before projections named their fields carries no
      # projection at all; the rest are the same defect spelled otherwise.
      unnamed = [
        Map.delete(resource, :projection),
        %{resource | projection: nil},
        %{resource | projection: %{scopes: []}},
        %{resource | projection: %{fields: [], scopes: []}},
        %{resource | projection: %{fields: "a", scopes: []}},
        %{resource | projection: %{fields: ["a", nil], scopes: []}},
        %{resource | projection: %{fields: ["a", ""], scopes: []}}
      ]

      for edge <- unnamed do
        log =
          capture_log(fn ->
            assert {:error, :corrupt} = VaultReader.fetch(ctx, edge)
          end)

        assert log =~ "re-consent to the component's current version"
        refute log =~ "sealed-"
      end

      # Refused before the entry is read: no use is recorded.
      assert last_used_at(ctx, entry) == before
    end

    test "a projected field the entry lacks refuses the whole resolution", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"url" => "https://db.example"})
      resource = %{resource | projection: %{fields: ["url", "anon_key"], scopes: []}}

      # Never the partial map with `url` alone, and never a silent skip.
      assert {:error, {:missing_field, "anon_key"}} = VaultReader.fetch(ctx, resource)
    end

    test "anonymous callers are refused before any load", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      assert {:error, :anonymous_denied} =
               VaultReader.fetch(%{ctx | anonymous: true}, resource)
    end

    test "a non-active entry is unavailable", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{status: "needs_reauth"})

      assert {:error, {:entry_unavailable, "needs_reauth"}} = VaultReader.fetch(ctx, resource)
    end

    test "a rebound entry fails at the derived binding digest", %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      import Ecto.Query

      Arca.Repo.update_all(
        from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
        set: [oauth_endpoints: ~s({"token_url":"https://evil.example/token"})]
      )

      assert {:error, :binding_mismatch} = VaultReader.fetch(ctx, resource)
    end

    test "a reader in another athanor gets nothing, and not a different nothing", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{name: "a-only"})
      foreign = %{ctx | athanor_id: "ath_other"}

      # The entry's own athanor column says the row belongs to the test
      # tenant; what decides the read is the caller's actor, and the answer
      # is byte-identical to one for an id that exists nowhere — a
      # different refusal would confirm the entry exists somewhere else.
      assert {:error, :not_found} = VaultReader.fetch(foreign, resource)

      assert VaultReader.fetch(foreign, resource) ==
               VaultReader.fetch(foreign, %{resource | entry_id: "vlt_nonexistent"})

      assert {:error, :not_found} = VaultReader.unseal_by_name("ath_other", "a-only")

      assert {:error, :not_found} =
               VaultReader.usable("ath_other", resource.entry_id, resource.binding_digest)

      # The same reads inside the owning athanor still answer.
      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource)
      assert {:ok, %{"k" => "v"}} = VaultReader.unseal_by_name(ctx.athanor_id, "a-only")
    end

    test "a payload with unknown keys is refused at decode", %{ctx: ctx} do
      id = Prima.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.athanor_id, id, "")
      {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":3,"fields":{},"extra":1}), aad)

      {:ok, entry} =
        Arca.VaultStorage.put(actor(ctx), %{
          id: id,
          name: "tampered",
          provider_hint: "",
          kind: "api_key",
          destination: @destination,
          attach_only: false,
          sealed_payload: sealed
        })

      {:ok, digest} = VaultReader.binding_digest(entry)
      resource = %{entry_id: id, binding_digest: digest, projection: %{fields: ["k"], scopes: []}}

      assert {:error, {:invalid_payload, {:unknown_keys, ["extra"]}}} =
               VaultReader.fetch(ctx, resource)
    end
  end

  describe "an attach-only entry" do
    test "is refused disclosure_refused by fetch/2 and oauth_token/3 before it is unsealed",
         %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          attach_only: true,
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "tok-attached", "token_type" => "bearer"},
          oauth_scopes: Jason.encode!(["gmail.readonly"])
        })

      # Its sealed bytes replaced by ones that would not open: a refusal
      # that came after an unseal would say so.
      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
          set: [sealed_payload: "not-a-ciphertext"]
        )

      before = last_used_at(ctx, entry)

      assert {:error, :disclosure_refused} = VaultReader.fetch(ctx, resource)

      token_edge = %{resource | projection: %{fields: [], scopes: ["gmail.readonly"]}}
      assert {:error, :disclosure_refused} = VaultReader.oauth_token(ctx, token_edge, "google")

      # Nothing was unsealed, so no use was recorded.
      assert last_used_at(ctx, entry) == before
    end

    test "disclosed later by a rebind, its fields are read under the new binding", %{ctx: ctx} do
      {entry, _resource} = mint_material_entry(ctx, %{"k" => "v"}, %{attach_only: true})

      {:ok, digest} = VaultReader.binding_digest(%{entry | attach_only: false})

      {:ok, _} =
        Arca.VaultStorage.move_binding(
          actor(ctx),
          entry.id,
          entry.binding_digest,
          %{attach_only: false, binding_digest: digest},
          "needs_consent"
        )

      resource = %{
        entry_id: entry.id,
        binding_digest: digest,
        projection: %{fields: ["k"], scopes: []}
      }

      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource)
    end
  end

  describe "the binding digest" do
    test "covers the destination and the disclosure, and derives none without them",
         %{ctx: ctx} do
      {entry, _resource} = mint_material_entry(ctx, %{"k" => "v"})
      {:ok, digest} = VaultReader.binding_digest(entry)

      moved = %{entry | destination: ~s({"hosts":["other.example.com"],"scheme":"https"})}
      assert {:ok, other} = VaultReader.binding_digest(moved)
      refute other == digest

      assert {:ok, attached} = VaultReader.binding_digest(%{entry | attach_only: true})
      refute attached == digest

      for broken <- [
            %{entry | destination: nil},
            %{entry | destination: ~s({"hosts":[]})},
            %{entry | destination: "not json"},
            %{entry | attach_only: nil},
            Map.delete(entry, :destination)
          ] do
        assert {:error, :invalid_binding} = VaultReader.binding_digest(broken)
      end
    end
  end

  describe "oauth_token/3 — material" do
    @valid_oauth %{"access_token" => "tok-live", "token_type" => "bearer"}
    @readonly Jason.encode!(["gmail.readonly"])

    test "dispenses a valid token without touching any provider", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a consent for one provider never dispenses another's token", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:error, {:provider_mismatch, "github"}} =
               VaultReader.oauth_token(ctx, resource, "github")
    end

    test "an OAuth entry serves only the provider it names, and one naming none serves none",
         %{ctx: ctx} do
      acme = ~s({"authorize_url":"https://acme.example/a","token_url":"https://acme.example/t"})

      # An entry of one provider, created with its own endpoints, never
      # stands in for another's dispense, a preset provider's included.
      {_entry, of_acme} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "acme",
          oauth: @valid_oauth,
          oauth_endpoints: acme,
          oauth_scopes: @readonly
        })

      assert {:error, {:provider_mismatch, "google"}} =
               VaultReader.oauth_token(ctx, of_acme, "google")

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, of_acme, "acme")

      # An entry naming no provider, as no create writes one now, serves no
      # provider's dispense at all.
      {_entry, of_none} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "",
          oauth: @valid_oauth,
          oauth_endpoints: acme,
          oauth_scopes: @readonly
        })

      for provider <- ["google", "acme", ""] do
        assert {:error, {:provider_mismatch, ^provider}} =
                 VaultReader.oauth_token(ctx, of_none, provider)
      end
    end

    test "a scope projection outside the entry's authorized scopes is unsatisfiable",
         %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: Jason.encode!(["gmail.readonly"])
        })

      resource =
        Map.put(resource, :projection, %{fields: [], scopes: ["gmail.readonly", "gmail.send"]})

      assert {:error, {:scope_projection_unsatisfiable, ["gmail.send"]}} =
               VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a narrower projection never dispenses the full-scope token", %{ctx: ctx} do
      # Google's preset does not attenuate a refresh, so a token for fewer
      # scopes than the entry holds cannot be had: the entry's broader one
      # is never served in its place, whether it is live or expired, and no
      # refresh is attempted for it.
      attempts = attach_refresh_counter()
      live = %{"access_token" => "tok-wide", "refresh_token" => "rt-1", "token_type" => "bearer"}
      expired = Map.put(live, "expires_at", "2020-01-01T00:00:00Z")

      for oauth <- [live, expired] do
        {_entry, resource} =
          mint_material_entry(ctx, %{}, %{
            provider_hint: "google",
            oauth: oauth,
            oauth_endpoints: ~s({"token_url":"https://127.0.0.1:1/tok"}),
            oauth_scopes: Jason.encode!(["gmail.readonly", "gmail.send"])
          })

        narrower = Map.put(resource, :projection, %{fields: [], scopes: ["gmail.readonly"]})

        assert {:error, :scope_not_attenuable} =
                 VaultReader.oauth_token(ctx, narrower, "google")
      end

      assert :counters.get(attempts, 1) == 0

      # The whole projection is still served the entry's own token.
      {_entry, whole} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: live,
          oauth_scopes: Jason.encode!(["gmail.readonly", "gmail.send"])
        })

      assert {:ok, "tok-wide"} = VaultReader.oauth_token(ctx, whole, "google")
    end

    test "a projection naming the entry's scopes in another order is the whole grant",
         %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: Jason.encode!(["gmail.readonly", "gmail.send"])
        })

      reordered =
        Map.put(resource, :projection, %{fields: [], scopes: ["gmail.send", "gmail.readonly"]})

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, reordered, "google")
    end

    test "a material entry without an oauth bundle has no token to dispense", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          provider_hint: "google",
          oauth_scopes: @readonly
        })

      assert {:error, :no_oauth_material} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "an OAuth edge that names no scopes is corrupt and dispenses nothing", %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      before = last_used_at(ctx, entry)

      for edge <- [
            Map.delete(resource, :projection),
            %{resource | projection: nil},
            %{resource | projection: %{fields: [], scopes: []}},
            %{resource | projection: %{fields: [], scopes: [""]}}
          ] do
        log =
          capture_log(fn ->
            assert {:error, :corrupt} = VaultReader.oauth_token(ctx, edge, "google")
          end)

        assert log =~ "re-consent to the component's current version"
        refute log =~ "tok-live"
      end

      assert last_used_at(ctx, entry) == before
    end

    test "a key edge carries no OAuth grant, whatever its entry holds", %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      key_edge = %{resource | projection: %{fields: ["k"], scopes: []}}
      before = last_used_at(ctx, entry)

      assert {:error, :no_oauth_material} = VaultReader.oauth_token(ctx, key_edge, "google")
      assert last_used_at(ctx, entry) == before
    end

    test "anonymous callers are refused before any load", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:error, :anonymous_denied} =
               VaultReader.oauth_token(%{ctx | anonymous: true}, resource, "google")
    end
  end

  # A provider no shipped preset is, shown to attenuate a refresh: its
  # preset says a refresh's `scope` yields a token limited to it, and its
  # token endpoint answers what the test scripts, in order, telling the
  # test each request it was sent (`:sanctum, :scripted_oauth_provider`).
  defmodule ScriptedProvider do
    @moduledoc false

    @hint "scripted-idp"
    @endpoints %{
      "authorize_url" => "https://idp.scripted.test/authorize",
      "token_url" => "https://idp.scripted.test/token"
    }

    def hint, do: @hint
    def endpoints, do: @endpoints

    def preset(@hint), do: %{endpoints: @endpoints, attenuates_scope: true}
    def preset(_hint), do: nil

    def post(url, _headers, body) do
      {test, answer} =
        Agent.get_and_update(__MODULE__, fn
          {test, [next | rest]} -> {{test, next}, {test, rest}}
          {test, []} -> {{test, {:error, "unscripted request"}}, {test, []}}
        end)

      send(test, {:token_request, url, URI.decode_query(body)})
      answer
    end
  end

  describe "oauth_token/3 — a provider that attenuates a refresh" do
    @wide ["mail.read", "mail.send"]
    @bundle %{
      "access_token" => "tok-wide",
      "refresh_token" => "rt-1",
      "token_type" => "bearer",
      "scopes" => @wide
    }

    setup %{ctx: ctx} do
      prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)
      Application.put_env(:sanctum, :scripted_oauth_provider, ScriptedProvider)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
          :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
        end
      end)

      hint = ScriptedProvider.hint()

      entering =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "oauth.set_client",
          arguments: %{provider: hint, client_id: "cid", client_secret: "csec"},
          resource: hint
        })

      :ok = Sanctum.ProviderCredentials.put(entering, hint, "cid", "csec")

      {entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: hint,
          oauth: @bundle,
          oauth_endpoints: Jason.encode!(ScriptedProvider.endpoints()),
          oauth_scopes: Jason.encode!(@wide)
        })

      narrower = Map.put(resource, :projection, %{fields: [], scopes: ["mail.read"]})
      %{entry: entry, whole: resource, narrower: narrower}
    end

    defp script!(answers) do
      test = self()

      start_supervised!(%{
        id: ScriptedProvider,
        start: {Agent, :start_link, [fn -> {test, answers} end, [name: ScriptedProvider]]}
      })

      :ok
    end

    defp held(ctx, entry) do
      {:ok, row} = Arca.VaultStorage.get(actor(ctx), entry.id)
      aad = CipherAAD.vault_entry(ctx.athanor_id, entry.id, entry.provider_hint)
      {:ok, plaintext} = Sanctum.Cipher.decrypt(row.sealed_payload, aad)
      {:ok, payload} = Payload.decode(plaintext)
      {row, payload["oauth"]}
    end

    test "dispenses a token obtained with the narrower scope, then holds it", %{
      ctx: ctx,
      entry: entry,
      whole: whole,
      narrower: narrower
    } do
      script!([
        {:ok, %{"access_token" => "tok-narrow", "scope" => "mail.read", "expires_in" => 3600}}
      ])

      assert {:ok, "tok-narrow"} = VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())

      # The refresh asked for exactly the projected scopes, with the
      # entry's refresh token, at the entry's own token endpoint.
      assert_received {:token_request, "https://idp.scripted.test/token", params}
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "rt-1"
      assert params["scope"] == "mail.read"

      {_row, oauth} = held(ctx, entry)
      assert %{"mail.read" => %{"access_token" => "tok-narrow"}} = oauth["tokens"]
      assert oauth["access_token"] == "tok-wide"

      # The same projection again is answered from what is held: one
      # refresh, then the cache.
      assert {:ok, "tok-narrow"} = VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())
      refute_received {:token_request, _, _}

      # And the whole projection is still the entry's own token.
      assert {:ok, "tok-wide"} = VaultReader.oauth_token(ctx, whole, ScriptedProvider.hint())
    end

    test "refuses when the provider answers wider, holding nothing", %{
      ctx: ctx,
      entry: entry,
      narrower: narrower
    } do
      script!([
        {:ok, %{"access_token" => "tok-wider", "scope" => "mail.read mail.send"}},
        {:ok, %{"access_token" => "tok-elsewhere", "scope" => "mail.read calendar"}}
      ])

      for _answer <- 1..2 do
        assert {:error, :scope_not_attenuable} =
                 VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())

        assert_received {:token_request, _, %{"scope" => "mail.read"}}
      end

      {row, oauth} = held(ctx, entry)
      refute Map.has_key?(oauth, "tokens")
      assert oauth["access_token"] == "tok-wide"
      assert oauth["refresh_token"] == "rt-1"
      assert row.payload_rev == entry.payload_rev
    end

    test "refuses an answer naming no scope, and keeps the refresh token it rotated", %{
      ctx: ctx,
      entry: entry,
      narrower: narrower
    } do
      script!([
        {:ok, %{"access_token" => "tok-unsaid", "refresh_token" => "rt-2", "expires_in" => 3600}}
      ])

      assert {:error, :scope_not_attenuable} =
               VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())

      # The provider may already have retired rt-1 on answering, so its
      # successor is kept, while the access token it named is neither held
      # nor dispensed.
      {_row, oauth} = held(ctx, entry)
      refute Map.has_key?(oauth, "tokens")
      assert oauth["refresh_token"] == "rt-2"
      assert oauth["access_token"] == "tok-wide"
    end

    test "callers asking for one scope set at once share one refresh", %{
      ctx: ctx,
      narrower: narrower
    } do
      script!([
        {:ok, %{"access_token" => "tok-narrow", "scope" => "mail.read", "expires_in" => 3600}}
      ])

      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn -> VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint()) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &(&1 == {:ok, "tok-narrow"}))
      assert_received {:token_request, _, _}
      refute_received {:token_request, _, _}
    end

    test "a full-scope refresh keeps the tokens held for narrower scope sets", %{
      ctx: ctx,
      entry: entry,
      whole: whole,
      narrower: narrower
    } do
      script!([
        {:ok, %{"access_token" => "tok-narrow", "scope" => "mail.read", "expires_in" => 3600}},
        {:ok, %{"access_token" => "tok-wide-2", "expires_in" => 3600}}
      ])

      assert {:ok, "tok-narrow"} = VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())

      # The entry's own token expires; its refresh sends no scope.
      {_row, oauth} = held(ctx, entry)
      expire_whole!(ctx, entry, oauth)

      assert {:ok, "tok-wide-2"} = VaultReader.oauth_token(ctx, whole, ScriptedProvider.hint())
      assert_received {:token_request, _, %{"scope" => "mail.read"}}
      assert_received {:token_request, _, full}
      refute Map.has_key?(full, "scope")

      {_row, oauth} = held(ctx, entry)
      assert %{"mail.read" => %{"access_token" => "tok-narrow"}} = oauth["tokens"]
      assert {:ok, "tok-narrow"} = VaultReader.oauth_token(ctx, narrower, ScriptedProvider.hint())
    end

    defp expire_whole!(ctx, entry, oauth) do
      {:ok, row} = Arca.VaultStorage.get(actor(ctx), entry.id)
      aad = CipherAAD.vault_entry(ctx.athanor_id, entry.id, entry.provider_hint)
      expired = Map.put(oauth, "expires_at", "2020-01-01T00:00:00Z")
      {:ok, json} = Payload.encode_material(%{}, expired)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)
      :ok = Arca.VaultStorage.rotate_payload(actor(ctx), entry.id, row.payload_rev, sealed)
    end
  end

  defp attach_refresh_counter do
    counter = :counters.new(1, [:atomics])
    handler_id = "vault-reader-refresh-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:cyfr, :sanctum, :vault, :oauth_refresh],
      fn _event, _measure, %{status: status}, _cfg ->
        if status == :attempt, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    counter
  end
end
