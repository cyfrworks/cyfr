# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AttachTest do
  @moduledoc """
  `Sanctum.Attach.resolve/5` decides the value CYFR attaches to one
  request, from the vault resource of the running node's edge and what the
  attempt knows of its run, never from the request: one value or none,
  the binding's lifetime at its `consent_vault_refs` row (a `once`
  consumed by its root, an expired `until` refused, a moved or blocked
  pin refused, a missing row refused), then an athanor's entry held to its
  binding and destination, a share resolved through its owner's entry
  under the digest the consent approved, refused when it is OAuth, or a
  publisher's provided value held to its destination. A refusal touches
  nothing it comes before: no row is consumed, no use counted and nothing
  unsealed.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Attach
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TestContext

  @secret "sk-attach-material"
  @rule %{in: "header", name: "x-api-key", template: "{value}"}
  @source "catalyst:local.attach-chat"
  @destination %{"hosts" => ["api.example.com"], "methods" => ["GET", "POST"]}
  @share_destination %{
    "hosts" => ["api.example.com"],
    "methods" => ["GET"],
    "paths" => ["/v1/"]
  }

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {person, _user} = TestContext.person!(TestContext.local())
    {:ok, ctx: person}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp request(url, method \\ "POST"), do: %{uri: URI.parse(url), method: method}

  # An athanor entry, attach-only unless `over` says otherwise, and its row.
  defp entry!(ctx, over \\ %{}) do
    {:ok, view} =
      TestContext.create_vault(
        ctx,
        Map.merge(
          %{
            name: "attach-#{System.unique_integer([:positive])}",
            kind: "api_key",
            provider_hint: "example.com",
            fields: %{"KEY" => @secret},
            destination: @destination
          },
          over
        )
      )

    {:ok, entry} = Arca.VaultStorage.get(Context.actor(ctx), view.id)
    entry
  end

  # A profile whose head binds `entry` at the binding key `key` with
  # `lifetime`, and the vault resource and facts a run under it carries.
  defp bound!(ctx, entry, opts \\ []) do
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
    key = Prima.Authority.Blob.binding_key(@source, Prima.Authority.Blob.ingress_key(), nil)
    {:ok, destination} = entry.destination |> Jason.decode!() |> Prima.Destination.from_map()

    ref =
      Map.merge(
        %{binding_key: key, vault_entry_id: entry.id, binding_digest: digest},
        Keyword.get(opts, :lifetime, %{})
      )

    {profile_id, consent_id} = head!(ctx, [ref])

    vault = %{
      entry_id: entry.id,
      binding_digest: digest,
      scope: "athanor",
      binding_key: key,
      destination: destination,
      attach: @rule,
      projection: Keyword.get(opts, :projection, %{fields: %{"KEY" => "KEY"}, scopes: []})
    }

    {vault, facts(profile_id, consent_id)}
  end

  defp head!(ctx, refs) do
    profile_id = "prof-attach-#{System.unique_integer([:positive])}"
    consent_id = Prima.UUID7.generate_id("cons")

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: profile_id, source_ref: @source, kind: :owner, label: profile_id},
        %{
          id: consent_id,
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          resolved_policy: "{}",
          activation: %{},
          vault_refs: refs
        }
      )

    {profile_id, consent_id}
  end

  defp facts(profile_id, consent_id, root \\ "exec_root_one"),
    do: %{root_execution_id: root, profile_id: profile_id, consent_id: consent_id}

  defp ref_row(consent_id) do
    Arca.Repo.one!(from(r in Arca.Schemas.ConsentVaultRef, where: r.consent_id == ^consent_id))
  end

  defp last_used(ctx, entry) do
    {:ok, row} = Arca.VaultStorage.get(Context.actor(ctx), entry.id)
    row.last_used_at
  end

  # A person signed in at this CYFR, in their own athanor, where a share
  # is made and granted.
  defp own!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "local|local|attach-#{n}", provider: "local", name: name})

    Context.build(
      user_id: user.id,
      provider: "local",
      namespace: "attach#{n}",
      athanor_id: Sanctum.Test.People.athanor!(user).id,
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # The owner's attach-only key shared with everyone, its row and the
  # share, under the proof the creation asks.
  defp shared!(owner) do
    entry = entry!(owner, %{destination: @share_destination})

    {:ok, share} =
      TestContext.confirming(
        owner,
        &Sanctum.Shares.create(&1, %{entry_id: entry.id, audience: "everyone"})
      )

    {entry, share}
  end

  # The recipient's profile whose head binds `share` at the digest of its
  # source, and the vault resource a run under it carries, naming the
  # share and the digest `digest` (the approved one unless given).
  defp share_bound!(recipient, entry, share, opts \\ []) do
    {:ok, approved} = Sanctum.VaultReader.binding_digest(entry)
    key = Prima.Authority.Blob.binding_key(@source, Prima.Authority.Blob.ingress_key(), nil)

    {profile_id, consent_id} =
      head!(recipient, [
        %{
          binding_key: key,
          share_id: share.id,
          binding_digest: approved,
          admitted: %{audience: share.audience, group_id: share.group_id}
        }
      ])

    {:ok, destination} = Prima.Destination.from_map(@share_destination)

    vault = %{
      entry_id: share.id,
      binding_digest: Keyword.get(opts, :digest, approved),
      scope: "share",
      binding_key: key,
      destination: destination,
      attach: @rule,
      projection: Keyword.get(opts, :projection, %{fields: %{"MARKET_KEY" => "KEY"}, scopes: []})
    }

    {vault, facts(profile_id, consent_id)}
  end

  defp share_usage(owner, share) do
    {:ok, usage} = Arca.ShareUsage.usage(Context.actor(owner), share.id, 2)
    usage
  end

  # ---------------------------------------------------------------------------
  # An athanor's entry
  # ---------------------------------------------------------------------------

  describe "an athanor's entry" do
    test "attaches its one projected field by the binding's rule, attach-only as it is", %{
      ctx: ctx
    } do
      entry = entry!(ctx)
      refute Sanctum.Vault.disclosed?(ctx, entry.name)
      {vault, facts} = bound!(ctx, entry)

      assert {:ok, %{value: @secret, attach: @rule, masking: [@secret]}} =
               Attach.resolve(ctx, vault, "api_key", request("https://api.example.com/v1"), facts)
    end

    test "a request outside its destination is refused, by scheme, port, host or method", %{
      ctx: ctx
    } do
      entry = entry!(ctx)
      {vault, facts} = bound!(ctx, entry)

      for {url, method} <- [
            {"http://api.example.com/v1", "POST"},
            {"https://api.example.com:8443/v1", "POST"},
            {"https://other.example.com/v1", "POST"},
            {"https://api.example.com/v1", "DELETE"}
          ] do
        assert {:error, :destination_mismatch} =
                 Attach.resolve(ctx, vault, "api_key", request(url, method), facts),
               "#{method} #{url}"
      end
    end

    test "the one field a key map names is the one attached", %{ctx: ctx} do
      entry = entry!(ctx, %{fields: %{"API key" => @secret, "ORG" => "org-1"}})
      url = request("https://api.example.com/v1")

      {vault, facts} =
        bound!(ctx, entry, projection: %{fields: %{"GROK_API_KEY" => "API key"}, scopes: []})

      assert {:ok, %{value: @secret, masking: [@secret]}} =
               Attach.resolve(ctx, vault, "api_key", url, facts)

      other = %{vault | projection: %{fields: %{"GROK_API_KEY" => "ORG"}, scopes: []}}

      assert {:ok, %{value: "org-1", masking: ["org-1"]}} =
               Attach.resolve(ctx, other, "api_key", url, facts)

      # An entry field the material lacks is refused by the component's name.
      absent = %{vault | projection: %{fields: %{"GROK_API_KEY" => "SECRET"}, scopes: []}}

      assert {:error, {:missing_field, "GROK_API_KEY"}} =
               Attach.resolve(ctx, absent, "api_key", url, facts)
    end

    test "a map naming two fields is ambiguous, with nothing consumed or unsealed", %{
      ctx: ctx
    } do
      entry = entry!(ctx, %{fields: %{"KEY" => @secret, "ORG" => "org-1"}})
      before = last_used(ctx, entry)

      {vault, facts} =
        bound!(ctx, entry,
          projection: %{fields: %{"KEY" => "KEY", "ORG" => "ORG"}, scopes: []},
          lifetime: %{lifetime_kind: "once"}
        )

      assert {:error, {:ambiguous, [key]}} =
               Attach.resolve(ctx, vault, "api_key", request("https://api.example.com/v1"), facts)

      assert key == vault.binding_key
      assert ref_row(facts.consent_id).consumed_by_root == nil
      assert last_used(ctx, entry) == before
    end

    test "an OAuth projection attaches the token dispensed for its scopes", %{ctx: ctx} do
      entry =
        entry!(ctx, %{
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "ya29.attach"},
          oauth_scopes: ["scope.a"]
        })

      {vault, facts} = bound!(ctx, entry, projection: %{fields: %{}, scopes: ["scope.a"]})

      assert {:ok, %{value: "ya29.attach", masking: ["ya29.attach"]}} =
               Attach.resolve(ctx, vault, "gmail", request("https://api.example.com/v1"), facts)
    end

    test "a rebound entry is refused under the binding the consent approved", %{ctx: ctx} do
      entry = entry!(ctx)
      {vault, facts} = bound!(ctx, entry)

      {:ok, _} =
        TestContext.confirming(
          ctx,
          &Sanctum.Vault.rebind(&1, %{
            id: entry.id,
            destination: %{"hosts" => ["api.example.com"], "paths" => ["/v2/"]}
          })
        )

      url = request("https://api.example.com/v1")

      # The rebind blocks the profile that bound it: the run's pin no
      # longer stands.
      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, facts)

      # Even under a profile active again, the entry is held to the digest
      # the consent approved.
      :ok = Arca.ProfileStorage.transition(Context.actor(ctx), facts.profile_id, :any, "active")
      assert {:error, :binding_mismatch} = Attach.resolve(ctx, vault, "api_key", url, facts)
    end

    test "a disclose-only binding, no binding and an anonymous caller attach nothing", %{
      ctx: ctx
    } do
      entry = entry!(ctx)
      {vault, facts} = bound!(ctx, entry)
      url = request("https://api.example.com/v1")

      assert {:error, :connection_not_granted} =
               Attach.resolve(ctx, %{vault | attach: nil}, "api_key", url, facts)

      assert {:error, :connection_not_granted} = Attach.resolve(ctx, nil, "api_key", url, facts)

      assert {:error, :connection_not_granted} =
               Attach.resolve(
                 ctx,
                 %{via: %{label: "x", binding_digest: nil}},
                 "api_key",
                 url,
                 facts
               )

      assert {:error, :anonymous_denied} =
               Attach.resolve(%{ctx | anonymous: true}, vault, "api_key", url, facts)
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetimes at use
  # ---------------------------------------------------------------------------

  describe "the binding's lifetime" do
    test "an until past its instant is refused before anything is unsealed", %{ctx: ctx} do
      entry = entry!(ctx)
      before = last_used(ctx, entry)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {vault, facts} =
        bound!(ctx, entry, lifetime: %{lifetime_kind: "until", expires_at: past})

      assert {:error, :grant_expired} =
               Attach.resolve(ctx, vault, "api_key", request("https://api.example.com/v1"), facts)

      assert last_used(ctx, entry) == before

      future = DateTime.add(DateTime.utc_now(), 600, :second)
      {vault, facts} = bound!(ctx, entry, lifetime: %{lifetime_kind: "until", expires_at: future})

      assert {:ok, %{value: @secret}} =
               Attach.resolve(ctx, vault, "api_key", request("https://api.example.com/v1"), facts)
    end

    test "a once binding is its first root's: that root again is admitted, another refused", %{
      ctx: ctx
    } do
      entry = entry!(ctx)
      {vault, facts} = bound!(ctx, entry, lifetime: %{lifetime_kind: "once"})
      url = request("https://api.example.com/v1")

      assert {:ok, %{value: @secret}} = Attach.resolve(ctx, vault, "api_key", url, facts)
      assert ref_row(facts.consent_id).consumed_by_root == "exec_root_one"
      assert {:ok, %{value: @secret}} = Attach.resolve(ctx, vault, "api_key", url, facts)

      other = %{facts | root_execution_id: "exec_root_two"}
      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, other)
      assert ref_row(facts.consent_id).consumed_by_root == "exec_root_one"
    end

    test "a head that moved, a blocked profile and a missing row are refused, never standing", %{
      ctx: ctx
    } do
      entry = entry!(ctx)
      url = request("https://api.example.com/v1")

      # The run's pin names a consent that is no longer the head.
      {vault, facts} = bound!(ctx, entry)
      moved = %{facts | consent_id: Prima.UUID7.generate_id("cons")}
      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, moved)

      # The profile is blocked under the run.
      {vault, facts} = bound!(ctx, entry)

      :ok =
        Arca.ProfileStorage.transition(
          Context.actor(ctx),
          facts.profile_id,
          :any,
          "needs_consent"
        )

      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, facts)

      # The head holds no row at the binding's key.
      {vault, facts} = bound!(ctx, entry)
      orphan = %{vault | binding_key: "#{@source}|@ingress|name:other"}
      assert {:error, :grant_expired} = Attach.resolve(ctx, orphan, "api_key", url, facts)
    end

    test "a borrowed binding answers to the lender's row as well", %{ctx: ctx} do
      entry = entry!(ctx)
      {lender_vault, lender_facts} = bound!(ctx, entry, lifetime: %{lifetime_kind: "once"})
      key = "reagent:local.borrower|#{@source}|default"

      {profile_id, consent_id} =
        head!(ctx, [%{binding_key: key, via_label: "default"}])

      vault =
        Map.merge(lender_vault, %{
          binding_key: key,
          lender: %{
            profile_id: lender_facts.profile_id,
            consent_id: lender_facts.consent_id,
            binding_key: lender_vault.binding_key
          }
        })

      url = request("https://api.example.com/v1")
      facts = facts(profile_id, consent_id)

      assert {:ok, %{value: @secret}} = Attach.resolve(ctx, vault, "api_key", url, facts)
      assert ref_row(lender_facts.consent_id).consumed_by_root == "exec_root_one"

      other = %{facts | root_execution_id: "exec_root_two"}
      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, other)
    end
  end

  # ---------------------------------------------------------------------------
  # Provided configuration
  # ---------------------------------------------------------------------------

  describe "a publisher's provided value" do
    test "attaches its one value within its destination, and refuses two", %{ctx: ctx} do
      {:ok, destination} = Prima.Destination.from_map(%{"hosts" => ["db.example"]})
      provided = %{destination: destination, values: %{"anon_key" => "pk-public"}, attach: @rule}
      url = request("https://db.example/rest")
      facts = facts(nil, nil)

      assert {:ok, %{value: "pk-public", masking: ["pk-public"]}} =
               Attach.resolve(ctx, %{provided: provided}, "supabase", url, facts)

      assert {:error, :destination_mismatch} =
               Attach.resolve(
                 ctx,
                 %{provided: provided},
                 "supabase",
                 request("https://db.other/rest"),
                 facts
               )

      two = %{provided | values: %{"anon_key" => "pk-public", "url" => "https://db.example"}}

      assert {:error, {:ambiguous, ["supabase"]}} =
               Attach.resolve(ctx, %{provided: two}, "supabase", url, facts)
    end
  end

  # ---------------------------------------------------------------------------
  # A share
  # ---------------------------------------------------------------------------

  describe "a share" do
    test "attaches the one field its projection maps from the owner's entry, masked, and " <>
           "counts the use in the owner's athanor" do
      terry = own!("Terry")
      alice = own!("Alice")
      {entry, share} = shared!(terry)
      {vault, facts} = share_bound!(alice, entry, share)

      assert {:ok, %{value: @secret, attach: @rule, masking: [@secret]}} =
               Attach.resolve(
                 alice,
                 vault,
                 "api_key",
                 request("https://api.example.com/v1/quotes", "GET"),
                 facts
               )

      assert %{people: [%{user_id: user_id, count: 1}], totals: [%{count: 1}]} =
               share_usage(terry, share)

      assert user_id == alice.user_id
    end

    test "a request off the source's destination is refused, with no use counted" do
      terry = own!("Terry")
      alice = own!("Alice")
      {entry, share} = shared!(terry)
      {vault, facts} = share_bound!(alice, entry, share)

      for {url, method} <- [
            {"https://other.example.com/v1/quotes", "GET"},
            {"https://api.example.com/v1/quotes", "POST"},
            {"https://api.example.com/v2/quotes", "GET"}
          ] do
        assert {:error, :destination_mismatch} =
                 Attach.resolve(alice, vault, "api_key", request(url, method), facts),
               "#{method} #{url}"
      end

      assert share_usage(terry, share) == %{people: [], totals: []}
      assert last_used(terry, entry) == nil
    end

    test "an OAuth projection of a share attaches nothing, with no use counted" do
      terry = own!("Terry")
      alice = own!("Alice")
      {entry, share} = shared!(terry)

      {vault, facts} =
        share_bound!(alice, entry, share, projection: %{fields: %{}, scopes: ["scope.a"]})

      assert {:error, :no_oauth_material} =
               Attach.resolve(
                 alice,
                 vault,
                 "api_key",
                 request("https://api.example.com/v1/quotes", "GET"),
                 facts
               )

      assert share_usage(terry, share) == %{people: [], totals: []}
      assert last_used(terry, entry) == nil
    end

    test "a resource whose digest is not its source's is stale, with no use counted" do
      terry = own!("Terry")
      alice = own!("Alice")
      {entry, share} = shared!(terry)
      url = request("https://api.example.com/v1/quotes", "GET")

      for digest <- ["sha256:approved-elsewhere", nil] do
        {vault, facts} = share_bound!(alice, entry, share, digest: digest)

        assert {:error, :binding_went_stale} =
                 Attach.resolve(alice, vault, "api_key", url, facts),
               inspect(digest)
      end

      assert share_usage(terry, share) == %{people: [], totals: []}
      assert last_used(terry, entry) == nil
    end
  end
end
