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
  binding and destination, an instance entry held to the consented
  digest, refused when it is OAuth, and resolved under its policy,
  destination and caps, or a publisher's provided value held to its
  destination. A refusal touches nothing it comes before: no row is
  consumed, no cap claimed and nothing unsealed.
  """

  # The component-facts port and the platform settings are node-wide.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Attach
  alias Sanctum.Consent.Components
  alias Sanctum.Context
  alias Sanctum.InstanceEntries
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TestContext

  defmodule Facts do
    @moduledoc """
    A component-facts port the cases write: the registry rows a node
    reference names, and the release digest the install media ships for
    each, by node key.
    """
    @behaviour Sanctum.Consent.Components

    @rows {__MODULE__, :rows}
    @shipped {__MODULE__, :shipped}

    def put(rows, shipped) do
      :persistent_term.put(@rows, rows)
      :persistent_term.put(@shipped, shipped)
    end

    def clear do
      :persistent_term.erase(@rows)
      :persistent_term.erase(@shipped)
    end

    @impl true
    def resolve(_ctx, _component), do: {:error, :not_found}

    @impl true
    def resolve_verified(_ctx, _component), do: {:error, :not_found}

    @impl true
    def get_component(_ctx, name, version, publisher, type) do
      case Map.fetch(:persistent_term.get(@rows, %{}), {type, publisher, name, version}) do
        {:ok, row} -> {:ok, row}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def agent_rows(_ctx), do: {:ok, []}

    @impl true
    def shipped_nodes(_ctx, rows) do
      shipped = :persistent_term.get(@shipped, %{})

      answered =
        for row <- rows,
            key = Prima.ComponentRow.node_key(row),
            Map.has_key?(shipped, key),
            into: %{},
            do: {key, Map.fetch!(shipped, key)}

      {:ok, answered}
    end

    @impl true
    def newer_shipped(_ctx, _row), do: {:ok, nil}
  end

  @secret "sk-attach-material"
  @rule %{in: "header", name: "x-api-key", template: "{value}"}
  @source "catalyst:local.attach-chat"
  @destination %{"hosts" => ["api.example.com"], "methods" => ["GET", "POST"]}
  @instance_destination %{
    "hosts" => ["api.openai.com"],
    "methods" => ["GET", "POST"],
    "paths" => ["/v1/chat/completions"]
  }

  @custom %{node_ref: "catalyst:local.my-chat:1.0.0", activation_digest: "sha256:custom"}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    previous =
      try do
        Components.impl!()
      rescue
        Components.NotInstalledError -> nil
      end

    Components.install!(Facts)

    on_exit(fn ->
      Facts.clear()
      if previous, do: Components.install!(previous), else: Components.reset()
    end)

    Facts.put(
      %{
        {"catalyst", "local", "my-chat", "1.0.0"} => %{
          component_type: "catalyst",
          publisher: "local",
          name: "my-chat",
          version: "1.0.0"
        }
      },
      %{}
    )

    {person, _user} = TestContext.person!(TestContext.local())
    {admin, _admin} = TestContext.person!(%{TestContext.local() | platform_admin: true})
    {:ok, ctx: person, admin: admin}
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
        %{
          binding_key: key,
          scope: "athanor",
          vault_entry_id: entry.id,
          binding_digest: digest
        },
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
      projection: Keyword.get(opts, :projection, %{fields: ["KEY"], scopes: []})
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

  defp facts(profile_id, consent_id, root \\ "exec_root_one") do
    Map.merge(@custom, %{root_execution_id: root, profile_id: profile_id, consent_id: consent_id})
  end

  defp ref_row(consent_id) do
    Arca.Repo.one!(from(r in Arca.Schemas.ConsentVaultRef, where: r.consent_id == ^consent_id))
  end

  defp last_used(ctx, entry) do
    {:ok, row} = Arca.VaultStorage.get(Context.actor(ctx), entry.id)
    row.last_used_at
  end

  defp instance!(admin, over \\ %{}) do
    params =
      Map.merge(
        %{
          name: "shared-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          fields: %{"API_KEY" => @secret},
          destination: @instance_destination,
          audience: "everyone"
        },
        over
      )

    confirmed =
      TestContext.confirmed(admin, :credential_entry, %{
        operation: "instance_entry.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = InstanceEntries.create(confirmed, params)
    entry
  end

  defp instance_bound!(ctx, entry, digest \\ nil) do
    digest = digest || entry.binding_digest
    key = Prima.Authority.Blob.binding_key(@source, Prima.Authority.Blob.ingress_key(), nil)

    {profile_id, consent_id} =
      head!(ctx, [
        %{
          binding_key: key,
          scope: "instance",
          instance_entry_id: entry.id,
          binding_digest: entry.binding_digest
        }
      ])

    {:ok, destination} = Prima.Destination.from_map(@instance_destination)

    vault = %{
      entry_id: entry.id,
      binding_digest: digest,
      scope: "instance",
      binding_key: key,
      destination: destination,
      attach: @rule,
      projection: %{fields: ["API_KEY"], scopes: []}
    }

    {vault, facts(profile_id, consent_id)}
  end

  defp usage(entry_id) do
    {:ok, %{totals: totals}} = Arca.InstanceEntryUsage.usage(Prima.Actor.system(), entry_id, 1)
    Enum.sum(Enum.map(totals, & &1.count))
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

    test "a projection naming two fields is ambiguous, with nothing consumed or unsealed", %{
      ctx: ctx
    } do
      entry = entry!(ctx, %{fields: %{"KEY" => @secret, "ORG" => "org-1"}})
      before = last_used(ctx, entry)

      {vault, facts} =
        bound!(ctx, entry,
          projection: %{fields: ["KEY", "ORG"], scopes: []},
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
          oauth: %{"access_token" => "ya29.attach", "token_type" => "Bearer"},
          oauth_scopes: ["scope.a"]
        })

      {vault, facts} = bound!(ctx, entry, projection: %{fields: [], scopes: ["scope.a"]})

      assert {:ok, %{value: "ya29.attach", masking: ["ya29.attach"]}} =
               Attach.resolve(ctx, vault, "gmail", request("https://api.example.com/v1"), facts)
    end

    test "a rebound entry is refused under the binding the consent approved", %{ctx: ctx} do
      entry = entry!(ctx)
      {vault, facts} = bound!(ctx, entry)

      {:ok, _} =
        Sanctum.Vault.rebind(ctx, %{
          id: entry.id,
          destination: %{"hosts" => ["api.example.com"], "paths" => ["/v2/"]}
        })

      url = request("https://api.example.com/v1")

      # The rebind blocks the profile that bound it: the run's pin no
      # longer stands.
      assert {:error, :grant_expired} = Attach.resolve(ctx, vault, "api_key", url, facts)

      # Even under a profile active again, the entry is held to the digest
      # the consent approved.
      :ok = Arca.ProfileStorage.set_status(Context.actor(ctx), facts.profile_id, "active")
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
        Arca.ProfileStorage.set_status(Context.actor(ctx), facts.profile_id, "needs_consent")

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
        head!(ctx, [%{binding_key: key, scope: "athanor", via_label: "default"}])

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
  # An instance entry
  # ---------------------------------------------------------------------------

  describe "an instance entry" do
    test "under any, attaches for a consented custom node and counts one use", %{
      ctx: ctx,
      admin: admin
    } do
      entry = instance!(admin)
      {vault, facts} = instance_bound!(ctx, entry)
      url = request("https://api.openai.com/v1/chat/completions")

      assert {:ok, %{value: @secret}} = Attach.resolve(ctx, vault, "api_key", url, facts)
      assert usage(entry.id) == 1

      # Outside its live destination: refused before any claim.
      assert {:error, :destination_mismatch} =
               Attach.resolve(
                 ctx,
                 vault,
                 "api_key",
                 request("https://api.openai.com/v1/files"),
                 facts
               )

      assert usage(entry.id) == 1
    end

    test "under shipped, a custom node is refused with no claim, before and after tightening", %{
      ctx: ctx,
      admin: admin
    } do
      entry = instance!(admin)
      {vault, facts} = instance_bound!(ctx, entry)
      url = request("https://api.openai.com/v1/chat/completions")

      assert {:ok, _} = Attach.resolve(ctx, vault, "api_key", url, facts)
      assert usage(entry.id) == 1

      :ok = tighten!(entry)

      assert {:error, :component_not_admitted} =
               Attach.resolve(ctx, vault, "api_key", url, facts)

      assert usage(entry.id) == 1
    end

    test "a binding rebound since the consent is stale, with no claim", %{
      ctx: ctx,
      admin: admin
    } do
      entry = instance!(admin)
      {vault, facts} = instance_bound!(ctx, entry, "sha256:approved-elsewhere")

      assert {:error, :binding_went_stale} =
               Attach.resolve(
                 ctx,
                 vault,
                 "api_key",
                 request("https://api.openai.com/v1/chat/completions"),
                 facts
               )

      assert usage(entry.id) == 0
    end

    test "an OAuth instance entry attaches nothing, with no claim or unseal", %{
      ctx: ctx,
      admin: admin
    } do
      # Creating one is refused (`Sanctum.InstanceEntries.create/2`), so the
      # row is written by the store directly.
      api = instance!(admin)
      {:ok, stored} = Arca.InstanceEntries.get(Prima.Actor.system(), api.id)

      {:ok, oauth} =
        Arca.InstanceEntries.put(Prima.Actor.system(), %{
          name: "shared-oauth-#{System.unique_integer([:positive])}",
          kind: "oauth",
          provider_hint: "google",
          field_names: "[]",
          binding_digest: stored.binding_digest,
          destination: stored.destination,
          status: "active",
          sealed_payload: "never opened",
          audience: "everyone",
          component_policy: "any",
          created_by: admin.user_id
        })

      {vault, facts} = instance_bound!(ctx, oauth)

      assert {:error, {:entry_unavailable, "oauth"}} =
               Attach.resolve(
                 ctx,
                 vault,
                 "api_key",
                 request("https://api.openai.com/v1/chat/completions"),
                 facts
               )

      assert usage(oauth.id) == 0
    end

    test "at its cap, refused with the reset", %{ctx: ctx, admin: admin} do
      entry = instance!(admin, %{person_daily: 1})
      {vault, facts} = instance_bound!(ctx, entry)
      url = request("https://api.openai.com/v1/chat/completions")

      assert {:ok, _} = Attach.resolve(ctx, vault, "api_key", url, facts)

      assert {:error, {:connection_cap, %DateTime{}}} =
               Attach.resolve(ctx, vault, "api_key", url, facts)

      assert usage(entry.id) == 1
    end
  end

  # The stored policy moved to `shipped`, as an administrator narrowing it
  # writes it.
  defp tighten!(entry),
    do:
      Arca.InstanceEntries.set_component_policy(Prima.Actor.system(), entry.id, "any", "shipped")
end
