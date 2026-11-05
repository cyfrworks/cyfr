# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MountTest do
  @moduledoc """
  `Sanctum.Mount.resolve/4` answers the kept home and the program row a
  run's binding of a login need mounts, never material, in order: the
  binding live (read, a `once` not consumed), a share refused as not
  built, the entry active at the consented digest and a login entry, the
  destination naming a program row that stands with a kept home, and only
  then the binding used, so a refused mount consumes nothing. Beside it,
  the reads the programs controller makes of login entries.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Mount
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TestContext

  @source "catalyst:local.mount-harness"
  @root "exec_mount_root"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {person, _user} = TestContext.person!(TestContext.local())
    {:ok, ctx: person}
  end

  defp login!(ctx, program \\ "claude", name \\ nil) do
    {:ok, view} =
      TestContext.create_vault(ctx, %{
        name: name || "login-#{System.unique_integer([:positive])}",
        kind: "login",
        program: program
      })

    {:ok, entry} = Arca.VaultStorage.get(Context.actor(ctx), view.id)
    entry
  end

  # A program row of the athanor, written as the row store writes one.
  defp row!(ctx, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id("mcp"),
          name: "claude",
          transport: "pipe",
          home: "kept",
          enabled: true,
          epoch: 1,
          revision: 0,
          config_json: ~s({"backends":[{"name":"claude","command":"claude"}]}),
          athanor_id: ctx.athanor_id,
          created_by: ctx.user_id
        },
        over
      )

    Arca.Repo.insert!(struct(Arca.Schemas.McpServer, attrs))
  end

  # A head binding `entry` at a key on the edge for `need`, and the
  # authority a run under it carries.
  defp bound!(ctx, entry, opts \\ []) do
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
    edge_key = Keyword.get(opts, :edge_key, Blob.edge_key("catalyst:local.dep", "claude"))
    key = Blob.binding_key(@source, edge_key, nil)
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
      scope: Keyword.get(opts, :scope, "athanor"),
      binding_key: key,
      destination: Keyword.get(opts, :destination, destination),
      attach: nil,
      projection: %{fields: %{}, scopes: []}
    }

    authority = %{
      Authority.zero()
      | profile_id: profile_id,
        consent_id: consent_id,
        resources: %Edge{vault: vault}
    }

    {authority, consent_id}
  end

  defp head!(ctx, refs) do
    profile_id = "prof-mount-#{System.unique_integer([:positive])}"
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

  defp consumed_by(consent_id) do
    Arca.Repo.one!(
      from(r in Arca.Schemas.ConsentVaultRef,
        where: r.consent_id == ^consent_id,
        select: r.consumed_by_root
      )
    )
  end

  @once %{lifetime: %{lifetime_kind: "once"}}

  describe "resolve/4" do
    test "answers the kept home and the program row, and nothing of the entry", %{ctx: ctx} do
      entry = login!(ctx)
      row = row!(ctx)
      {authority, _consent} = bound!(ctx, entry)

      assert {:ok, {:mount, home_id, mounted}} = Mount.resolve(ctx, authority, "claude", @root)
      assert home_id == entry.id
      assert mounted.id == row.id
      assert mounted.home == "kept"
    end

    test "a stdio row with a kept home is mounted too", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx, %{transport: "stdio"})
      {authority, _consent} = bound!(ctx, entry)

      assert {:ok, {:mount, _home, %{transport: "stdio"}}} =
               Mount.resolve(ctx, authority, "claude", @root)
    end

    test "a once binding is consumed by the mount that is made, and only by it", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx)
      {authority, consent_id} = bound!(ctx, entry, Map.to_list(@once))

      assert consumed_by(consent_id) == nil
      assert {:ok, {:mount, _, _}} = Mount.resolve(ctx, authority, "claude", @root)
      assert consumed_by(consent_id) == @root

      # Its own root mounts again; another root is refused.
      assert {:ok, {:mount, _, _}} = Mount.resolve(ctx, authority, "claude", @root)
      assert {:error, :grant_expired} = Mount.resolve(ctx, authority, "claude", "exec_other")
    end

    test "a binding of another need is not this need's", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx)

      {authority, consent_id} =
        bound!(
          ctx,
          entry,
          [edge_key: Blob.edge_key("catalyst:local.dep", "gemini")] ++ Map.to_list(@once)
        )

      assert {:error, :connection_not_granted} = Mount.resolve(ctx, authority, "claude", @root)
      assert consumed_by(consent_id) == nil
    end

    test "an expired binding is refused before the entry is read", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {authority, _consent} =
        bound!(ctx, entry, lifetime: %{lifetime_kind: "until", expires_at: past})

      assert {:error, :grant_expired} = Mount.resolve(ctx, authority, "claude", @root)
    end

    test "a share is refused as not built, consuming nothing", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx)
      {authority, consent_id} = bound!(ctx, entry, [scope: "share"] ++ Map.to_list(@once))

      assert {:error, {:not_built, :shared_login}} =
               Mount.resolve(ctx, authority, "claude", @root)

      assert consumed_by(consent_id) == nil
    end

    test "an entry no longer active is refused, consuming nothing", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx)
      {authority, consent_id} = bound!(ctx, entry, Map.to_list(@once))
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert {:error, {:entry_unavailable, _name, "revoked"}} =
               Mount.resolve(ctx, authority, "claude", @root)

      assert consumed_by(consent_id) == nil
    end

    test "an entry of another kind is not mounted, consuming nothing", %{ctx: ctx} do
      {:ok, view} =
        TestContext.create_vault(ctx, %{
          name: "key",
          kind: "api_key",
          fields: %{"K" => "secret-material"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      {:ok, entry} = Arca.VaultStorage.get(Context.actor(ctx), view.id)
      row!(ctx)
      {:ok, program} = Prima.Destination.from_map(%{"program" => "claude"})

      {authority, consent_id} =
        bound!(ctx, entry, [destination: program] ++ Map.to_list(@once))

      assert {:error, :not_mountable} = Mount.resolve(ctx, authority, "claude", @root)
      assert consumed_by(consent_id) == nil
    end

    test "a program row that does not stand as a kept program is refused, consuming nothing",
         %{ctx: ctx} do
      entry = login!(ctx)
      {authority, consent_id} = bound!(ctx, entry, Map.to_list(@once))

      # No row at all.
      assert {:error, {:program_unavailable, "claude"}} =
               Mount.resolve(ctx, authority, "claude", @root)

      for over <- [%{enabled: false}, %{home: "scratch"}] do
        row = row!(ctx, over)

        assert {:error, {:program_unavailable, "claude"}} =
                 Mount.resolve(ctx, authority, "claude", @root),
               inspect(over)

        Arca.Repo.delete!(row)
      end

      assert consumed_by(consent_id) == nil
    end

    test "a consent that approved another program does not mount this entry", %{ctx: ctx} do
      entry = login!(ctx)
      row!(ctx, %{name: "codex"})
      {:ok, codex} = Prima.Destination.from_map(%{"program" => "codex"})
      {authority, consent_id} = bound!(ctx, entry, [destination: codex] ++ Map.to_list(@once))

      assert {:error, {:program_unavailable, "codex"}} =
               Mount.resolve(ctx, authority, "claude", @root)

      assert consumed_by(consent_id) == nil
    end

    test "an anonymous caller is refused", %{ctx: ctx} do
      entry = login!(ctx)
      {authority, _consent} = bound!(ctx, entry)

      assert {:error, :anonymous_denied} =
               Mount.resolve(%{ctx | anonymous: true}, authority, "claude", @root)
    end
  end

  describe "the reads of login entries" do
    test "login_entry/3 answers the active login entry naming the program, by id or name",
         %{ctx: ctx} do
      entry = login!(ctx, "claude", "my-claude")

      assert {:ok, %{id: id, name: "my-claude"}} = Mount.login_entry(ctx, entry.id, "claude")
      assert id == entry.id
      assert {:ok, %{id: ^id}} = Mount.login_entry(ctx, "my-claude", "claude")

      assert {:error, {:another_program, "claude"}} = Mount.login_entry(ctx, entry.id, "codex")
      assert {:error, :not_found} = Mount.login_entry(ctx, "nobody", "claude")

      {:ok, key} =
        TestContext.create_vault(ctx, %{
          name: "key",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      assert {:error, :not_a_login_entry} = Mount.login_entry(ctx, key.id, "claude")

      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

      assert {:error, {:entry_unavailable, "revoked"}} =
               Mount.login_entry(ctx, entry.id, "claude")

      :ok = Sanctum.Vault.delete(ctx, entry.id)
      assert {:error, :not_found} = Mount.login_entry(ctx, entry.id, "claude")
    end

    test "a sign-in admits an entry a restore left needs_reauth, and its exit 0 makes it active",
         %{ctx: ctx} do
      entry = login!(ctx, "claude", "after-restore")
      actor = Sanctum.Context.actor(ctx)
      {:ok, _} = Arca.VaultStorage.set_status(actor, entry.id, "needs_reauth")

      # Nothing but a sign-in reaches it: a mount and a plain pick refuse it.
      assert {:error, {:entry_unavailable, "needs_reauth"}} =
               Mount.login_entry(ctx, entry.id, "claude")

      assert {:ok, %{id: id, status: "needs_reauth"}} =
               Mount.login_entry(ctx, entry.id, "claude", for: :sign_in)

      assert id == entry.id

      assert :ok = Mount.signed_in(ctx, entry.id)
      assert {:ok, %{status: "active"}} = Mount.login_entry(ctx, entry.id, "claude")

      # An active entry stays active, a revoked one is never brought back, and
      # an entry of another kind is no login entry.
      assert :ok = Mount.signed_in(ctx, entry.id)
      {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)
      assert {:error, {:entry_unavailable, "revoked"}} = Mount.signed_in(ctx, entry.id)

      assert {:error, {:entry_unavailable, "revoked"}} =
               Mount.login_entry(ctx, entry.id, "claude", for: :sign_in)

      {:ok, key} =
        TestContext.create_vault(ctx, %{
          name: "a-key",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      assert {:error, :not_a_login_entry} = Mount.signed_in(ctx, key.id)
    end

    test "login_entry/3 reads the context's athanor alone", %{ctx: ctx} do
      entry = login!(ctx)
      other = %{ctx | athanor_id: Prima.UUID7.generate_id("ath")}
      assert {:error, :not_found} = Mount.login_entry(other, entry.id, "claude")
    end

    test "home_of/2 names a login entry's home, a deleted one's included", %{ctx: ctx} do
      entry = login!(ctx)
      assert {:ok, home} = Mount.home_of(ctx.athanor_id, entry.id)
      assert home == entry.id

      :ok = Sanctum.Vault.delete(ctx, entry.id)
      assert {:ok, ^home} = Mount.home_of(ctx.athanor_id, entry.id)

      {:ok, key} =
        TestContext.create_vault(ctx, %{
          name: "key",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      assert :none = Mount.home_of(ctx.athanor_id, key.id)
      assert :none = Mount.home_of(ctx.athanor_id, "vlt_missing")
    end

    test "login_entries/1 lists the athanor's living login entries", %{ctx: ctx} do
      a = login!(ctx)
      b = login!(ctx, "codex")
      gone = login!(ctx)
      :ok = Sanctum.Vault.delete(ctx, gone.id)

      {:ok, _key} =
        TestContext.create_vault(ctx, %{
          name: "key",
          kind: "api_key",
          fields: %{"K" => "v"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      assert {:ok, ids} = Mount.login_entries(ctx.athanor_id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end
  end

  describe "an attach" do
    test "never attaches a login entry", %{ctx: ctx} do
      entry = login!(ctx)
      {authority, _consent} = bound!(ctx, entry)

      vault = %{
        authority.resources.vault
        | attach: %{in: "header", name: "x", template: "{value}"}
      }

      assert {:error, :connection_not_granted} =
               Sanctum.Attach.resolve(
                 ctx,
                 %{vault | projection: %{fields: %{"K" => "K"}, scopes: []}},
                 "claude",
                 %{uri: URI.parse("https://api.example.com/"), method: "POST"},
                 %{
                   root_execution_id: @root,
                   profile_id: authority.profile_id,
                   consent_id: authority.consent_id
                 }
               )
    end
  end
end
