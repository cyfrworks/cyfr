# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultReaderTest do
  use ExUnit.Case, async: false

  # What a dispense is made for, as an attempt names it. These resources
  # carry no binding key, so no binding lifetime is read for them.
  @dispense %{root_execution_id: "exec_reader_test", profile_id: nil, consent_id: nil}

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
      destination: Map.get(over, :destination, @destination),
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

  describe "fetch/3 — material" do
    test "projects the sealed fields; nothing outside the projection leaves", %{ctx: ctx} do
      fields = %{"url" => "https://db.example", "anon_key" => "anon", "service_key" => "SECRET"}
      {_entry, resource} = mint_material_entry(ctx, fields)
      resource = Map.put(resource, :projection, %{fields: ["url", "anon_key"], scopes: []})

      assert {:ok, resolved} = VaultReader.fetch(ctx, resource, @dispense)
      assert resolved == %{"url" => "https://db.example", "anon_key" => "anon"}
      refute Map.has_key?(resolved, "service_key")
    end

    test "an edge whose projection names no fields is corrupt and dispenses nothing",
         %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"a" => "sealed-a", "b" => "sealed-b"})
      before = last_used_at(ctx, entry)

      # An edge that carries no projection at all, and the same defect
      # spelled otherwise.
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
            assert {:error, :corrupt} = VaultReader.fetch(ctx, edge, @dispense)
          end)

        assert log =~ "consent to the component again"
        refute log =~ "sealed-"
      end

      # Refused before the entry is read: no use is recorded.
      assert last_used_at(ctx, entry) == before
    end

    test "a projected field the entry lacks refuses the whole resolution", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"url" => "https://db.example"})
      resource = %{resource | projection: %{fields: ["url", "anon_key"], scopes: []}}

      # Never the partial map with `url` alone, and never a silent skip.
      assert {:error, {:missing_field, "anon_key"}} = VaultReader.fetch(ctx, resource, @dispense)
    end

    test "anonymous callers are refused before any load", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      assert {:error, :anonymous_denied} =
               VaultReader.fetch(%{ctx | anonymous: true}, resource, @dispense)
    end

    test "a non-active entry is unavailable", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{status: "needs_reauth"})

      assert {:error, {:entry_unavailable, "needs_reauth"}} =
               VaultReader.fetch(ctx, resource, @dispense)
    end

    test "a rebound entry fails at the derived binding digest", %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      import Ecto.Query

      Arca.Repo.update_all(
        from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
        set: [oauth_endpoints: ~s({"token_url":"https://evil.example/token"})]
      )

      assert {:error, :binding_mismatch} = VaultReader.fetch(ctx, resource, @dispense)
    end

    test "a reader in another athanor gets nothing, and not a different nothing", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{name: "a-only"})
      foreign = %{ctx | athanor_id: "ath_other"}

      # The entry's own athanor column says the row belongs to the test
      # tenant; what decides the read is the caller's actor, and the answer
      # is byte-identical to one for an id that exists nowhere — a
      # different refusal would confirm the entry exists somewhere else.
      assert {:error, :not_found} = VaultReader.fetch(foreign, resource, @dispense)

      assert VaultReader.fetch(foreign, resource, @dispense) ==
               VaultReader.fetch(foreign, %{resource | entry_id: "vlt_nonexistent"}, @dispense)

      assert {:error, :not_found} =
               VaultReader.unseal_for("ath_other", "a-only", "https://api.example.com/mcp")

      assert {:error, :not_found} = VaultReader.unseal_disclosed("ath_other", "a-only")

      assert {:error, :not_found} =
               VaultReader.usable("ath_other", resource.entry_id, resource.binding_digest)

      # The same reads inside the owning athanor still answer.
      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource, @dispense)

      assert {:ok, %{"k" => "v"}} =
               VaultReader.unseal_for(ctx.athanor_id, "a-only", "https://api.example.com/mcp")

      assert {:ok, %{"k" => "v"}} = VaultReader.unseal_disclosed(ctx.athanor_id, "a-only")
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
               VaultReader.fetch(ctx, resource, @dispense)
    end
  end

  describe "an attach-only entry" do
    test "is refused disclosure_refused by fetch/3 and oauth_token/4 before it is unsealed",
         %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          attach_only: true,
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "tok-attached"},
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

      assert {:error, :disclosure_refused} = VaultReader.fetch(ctx, resource, @dispense)

      token_edge = %{resource | projection: %{fields: [], scopes: ["gmail.readonly"]}}

      assert {:error, :disclosure_refused} =
               VaultReader.oauth_token(ctx, token_edge, "google", @dispense)

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

      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource, @dispense)
    end
  end

  # A profile whose head binds `resource`'s entry at a binding key, with
  # `lifetime`; answers the resource carrying that key and the use a run
  # under the head dispenses for.
  defp bound(ctx, resource, lifetime) do
    key = "catalyst:local.reader-lifetime|@ingress|default"
    profile_id = "prof-reader-#{System.unique_integer([:positive])}"
    consent_id = Prima.UUID7.generate_id("cons")

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{
          id: profile_id,
          source_ref: "catalyst:local.reader-lifetime",
          kind: :owner,
          label: profile_id
        },
        %{
          id: consent_id,
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          resolved_policy: "{}",
          activation: %{},
          vault_refs: [
            Map.merge(
              %{
                binding_key: key,
                scope: "athanor",
                vault_entry_id: resource.entry_id,
                binding_digest: resource.binding_digest
              },
              lifetime
            )
          ]
        }
      )

    use = %{root_execution_id: "exec_root_one", profile_id: profile_id, consent_id: consent_id}
    {Map.put(resource, :binding_key, key), use}
  end

  defp consumed_by(use) do
    Arca.Repo.one!(
      Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
        where: r.consent_id == ^use.consent_id,
        select: r.consumed_by_root
      )
    )
  end

  describe "a binding's lifetime at dispense" do
    test "a disclosed once binding is consumed by its first dispense, for its root alone", %{
      ctx: ctx
    } do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"})
      {resource, use} = bound(ctx, resource, %{lifetime_kind: "once"})

      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource, use)
      assert consumed_by(use) == "exec_root_one"
      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource, use)

      assert {:error, :grant_expired} =
               VaultReader.fetch(ctx, resource, %{use | root_execution_id: "exec_root_two"})

      assert consumed_by(use) == "exec_root_one"
    end

    test "a token dispense is held to the binding's lifetime the same way", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "tok-once"},
          oauth_scopes: Jason.encode!(["gmail.readonly"])
        })

      {resource, use} = bound(ctx, resource, %{lifetime_kind: "once"})

      assert {:ok, "tok-once"} = VaultReader.oauth_token(ctx, resource, "google", use)

      assert {:error, :grant_expired} =
               VaultReader.oauth_token(ctx, resource, "google", %{
                 use
                 | root_execution_id: "exec_root_two"
               })

      # A refusal before the lifetime consumes nothing: another provider is
      # refused by name first.
      {_entry, other} =
        mint_material_entry(ctx, %{}, %{
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "tok-other"},
          oauth_scopes: Jason.encode!(["gmail.readonly"])
        })

      {other, other_use} = bound(ctx, other, %{lifetime_kind: "once"})

      assert {:error, {:provider_mismatch, "github"}} =
               VaultReader.oauth_token(ctx, other, "github", other_use)

      assert consumed_by(other_use) == nil
    end

    test "an until past its instant is refused before anything is unsealed", %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"k" => "v"})
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {resource, use} = bound(ctx, resource, %{lifetime_kind: "until", expires_at: past})
      before = last_used_at(ctx, entry)

      assert {:error, :grant_expired} = VaultReader.fetch(ctx, resource, use)
      assert last_used_at(ctx, entry) == before
    end

    test "an attach-only once binding is never consumed by a dispense", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{attach_only: true})
      {resource, use} = bound(ctx, resource, %{lifetime_kind: "once"})

      assert {:error, :disclosure_refused} = VaultReader.fetch(ctx, resource, use)
      assert consumed_by(use) == nil
    end

    test "a pin that is not the head, and a key the head holds no row for, are refused", %{
      ctx: ctx
    } do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"})
      {resource, use} = bound(ctx, resource, %{})

      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource, use)

      assert {:error, :grant_expired} =
               VaultReader.fetch(ctx, resource, %{use | consent_id: "cons_not_the_head"})

      assert {:error, :grant_expired} =
               VaultReader.fetch(
                 ctx,
                 %{resource | binding_key: "catalyst:local.reader-lifetime|@ingress|name:x"},
                 use
               )
    end
  end

  describe "unseal_for/3 — an http server's header entry" do
    # Its sealed bytes replaced by ones that would not open: a refusal that
    # came after an unseal would say so instead.
    defp unopenable!(entry) do
      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
          set: [sealed_payload: "not-a-ciphertext"]
        )
    end

    test "answers the fields for a URL its destination admits, and records the use",
         %{ctx: ctx} do
      {entry, _resource} = mint_material_entry(ctx, %{"k" => "v"}, %{name: "hdr"})

      assert {:ok, %{"k" => "v"}} =
               VaultReader.unseal_for(ctx.athanor_id, "hdr", "https://api.example.com/mcp")

      assert %DateTime{} = last_used_at(ctx, entry)
    end

    test "refuses destination_mismatch for a URL outside its destination, before it is unsealed",
         %{ctx: ctx} do
      {entry, _resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          name: "openai-key",
          destination: ~s({"hosts":["api.openai.com"],"paths":["/v1"],"scheme":"https"})
        })

      unopenable!(entry)
      before = last_used_at(ctx, entry)

      for url <- [
            # another host
            "https://evil.example/mcp",
            # the host, outside the entry's paths
            "https://api.openai.com/v2/mcp",
            # the host, another scheme
            "http://api.openai.com/v1/mcp",
            # the host, another port
            "https://api.openai.com:8443/v1/mcp",
            # the host, with user information
            "https://user@api.openai.com/v1/mcp",
            # no URL at all
            "not a url"
          ] do
        assert {:error, :destination_mismatch} =
                 VaultReader.unseal_for(ctx.athanor_id, "openai-key", url),
               url
      end

      assert last_used_at(ctx, entry) == before

      # Inside the destination, the same row is read, and its bytes do not open.
      assert {:error, :unseal_failed} =
               VaultReader.unseal_for(
                 ctx.athanor_id,
                 "openai-key",
                 "https://api.openai.com/v1/mcp"
               )
    end

    test "a wildcard host admits a name below it and not the name itself", %{ctx: ctx} do
      mint_material_entry(ctx, %{"k" => "v"}, %{
        name: "wild",
        destination: ~s({"hosts":["*.example.com"],"scheme":"https"})
      })

      assert {:ok, %{"k" => "v"}} =
               VaultReader.unseal_for(ctx.athanor_id, "wild", "https://mcp.example.com/mcp")

      assert {:error, :destination_mismatch} =
               VaultReader.unseal_for(ctx.athanor_id, "wild", "https://example.com/mcp")
    end

    test "an attach-only entry is attached to its destination: a header is no disclosure",
         %{ctx: ctx} do
      mint_material_entry(ctx, %{"k" => "v"}, %{name: "attached", attach_only: true})

      assert {:ok, %{"k" => "v"}} =
               VaultReader.unseal_for(ctx.athanor_id, "attached", "https://api.example.com/mcp")
    end

    test "a missing or inactive entry is refused", %{ctx: ctx} do
      mint_material_entry(ctx, %{"k" => "v"}, %{name: "revoked", status: "revoked"})
      url = "https://api.example.com/mcp"

      assert {:error, :not_found} = VaultReader.unseal_for(ctx.athanor_id, "absent", url)

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultReader.unseal_for(ctx.athanor_id, "revoked", url)
    end
  end

  describe "unseal_disclosed/2 — a stdio backend's env entry" do
    test "answers a disclosed entry's fields", %{ctx: ctx} do
      {entry, _resource} = mint_material_entry(ctx, %{"k" => "v"}, %{name: "env"})

      assert {:ok, %{"k" => "v"}} = VaultReader.unseal_disclosed(ctx.athanor_id, "env")
      assert %DateTime{} = last_used_at(ctx, entry)
    end

    test "refuses an attach-only entry disclosure_refused before it is unsealed", %{ctx: ctx} do
      {entry, _resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{name: "attach-only", attach_only: true})

      unopenable!(entry)
      before = last_used_at(ctx, entry)

      assert {:error, :disclosure_refused} =
               VaultReader.unseal_disclosed(ctx.athanor_id, "attach-only")

      assert last_used_at(ctx, entry) == before
    end

    test "a missing or inactive entry is refused", %{ctx: ctx} do
      mint_material_entry(ctx, %{"k" => "v"}, %{name: "revoked-env", status: "revoked"})

      assert {:error, :not_found} = VaultReader.unseal_disclosed(ctx.athanor_id, "absent")

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultReader.unseal_disclosed(ctx.athanor_id, "revoked-env")
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

  describe "usable/3" do
    # A store that cannot answer is not an entry that does not exist: a
    # consent read through it would tell the person the entry is gone.
    @tag :capture_log
    test "a store that cannot answer is unavailable; a row it does not hold is not found",
         %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"k" => "v"})
      usable = fn id -> VaultReader.usable(ctx.athanor_id, id, resource.binding_digest) end

      assert {:ok, %{id: id}} = usable.(entry.id)
      assert id == entry.id
      assert usable.("vlt_nonexistent") == {:error, :not_found}

      Arca.Repo.query!("ALTER TABLE vault_entries RENAME TO vault_entries_unavailable")

      assert usable.(entry.id) == {:error, {:unavailable, "Vault"}}
      assert usable.("vlt_nonexistent") == {:error, {:unavailable, "Vault"}}

      Arca.Repo.query!("ALTER TABLE vault_entries_unavailable RENAME TO vault_entries")
      assert usable.("vlt_nonexistent") == {:error, :not_found}
    end
  end

  describe "oauth_token/4 — material" do
    @valid_oauth %{"access_token" => "tok-live"}
    @readonly Jason.encode!(["gmail.readonly"])

    test "dispenses a valid token without touching any provider", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google", @dispense)
    end

    test "a consent for one provider never dispenses another's token", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:error, {:provider_mismatch, "github"}} =
               VaultReader.oauth_token(ctx, resource, "github", @dispense)
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
               VaultReader.oauth_token(ctx, of_acme, "google", @dispense)

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, of_acme, "acme", @dispense)

      # An entry naming no provider, which a create refuses and the store
      # holds only as damage, serves no provider's dispense at all.
      {_entry, of_none} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "",
          oauth: @valid_oauth,
          oauth_endpoints: acme,
          oauth_scopes: @readonly
        })

      for provider <- ["google", "acme", ""] do
        assert {:error, {:provider_mismatch, ^provider}} =
                 VaultReader.oauth_token(ctx, of_none, provider, @dispense)
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
               VaultReader.oauth_token(ctx, resource, "google", @dispense)
    end

    test "a narrower projection never dispenses the full-scope token", %{ctx: ctx} do
      # An entry holds one token, for its own scopes: the broader token is
      # never served for fewer, whether it is live or expired, and no
      # refresh is attempted for it.
      attempts = attach_refresh_counter()
      live = %{"access_token" => "tok-wide", "refresh_token" => "rt-1"}
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
                 VaultReader.oauth_token(ctx, narrower, "google", @dispense)
      end

      assert :counters.get(attempts, 1) == 0

      # The whole projection is still served the entry's own token.
      {_entry, whole} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: live,
          oauth_scopes: Jason.encode!(["gmail.readonly", "gmail.send"])
        })

      assert {:ok, "tok-wide"} = VaultReader.oauth_token(ctx, whole, "google", @dispense)
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

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, reordered, "google", @dispense)
    end

    test "a material entry without an oauth bundle has no token to dispense", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          provider_hint: "google",
          oauth_scopes: @readonly
        })

      assert {:error, :no_oauth_material} =
               VaultReader.oauth_token(ctx, resource, "google", @dispense)
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
            assert {:error, :corrupt} = VaultReader.oauth_token(ctx, edge, "google", @dispense)
          end)

        assert log =~ "consent to the component again"
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

      assert {:error, :no_oauth_material} =
               VaultReader.oauth_token(ctx, key_edge, "google", @dispense)

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
               VaultReader.oauth_token(%{ctx | anonymous: true}, resource, "google", @dispense)
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
