# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorTest do
  use ExUnit.Case, async: false

  alias Sanctum.Door
  alias Sanctum.Door.Store

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original = Application.get_env(:cyfr, :platform_admin_emails, [])
    Application.put_env(:cyfr, :platform_admin_emails, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:cyfr, :platform_admin_emails, original) end)
    :ok
  end

  defp uid(n), do: "github|https://github.com|#{n}"

  describe "admit/3 — the order of the door" do
    test "an empty list admits only the platform admins" do
      assert {:ok, :admin} = Door.admit(uid(1), "ops@example.com", true)
      assert {:ok, :admin} = Door.admit(uid(1), "OPS@example.com", :unknown)
      # A provider that positively says the operator's address is unverified
      # is a signal, not silence: the widest grant does not key on it.
      assert {:error, :not_allowed} = Door.admit(uid(1), "ops@example.com", false)
      assert {:error, :not_allowed} = Door.admit(uid(2), "bob@example.com", true)
    end

    test "an exact email entry admits only a verified email" do
      {:ok, _} = Store.allow("email", "Bob@Example.com", "ops")
      assert {:ok, :allowed} = Door.admit(uid(2), "bob@example.com", true)
      assert {:error, :not_allowed} = Door.admit(uid(2), "bob@example.com", :unknown)
      assert {:error, :not_allowed} = Door.admit(uid(2), "bob@example.com", false)
    end

    test "a user_id entry admits an issuer that proves nothing about the email" do
      {:ok, _} = Store.allow("user_id", uid(3), "ops")
      assert {:ok, :allowed} = Door.admit(uid(3), "carol@example.com", :unknown)
      assert {:ok, :allowed} = Door.admit(uid(3), nil, :unknown)
    end

    test "* admits anyone the provider authenticates, unless the email is known unverified" do
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      assert {:ok, :allowed} = Door.admit(uid(4), "dave@example.com", true)
      assert {:ok, :allowed} = Door.admit(uid(4), "dave@example.com", :unknown)
      assert {:error, :not_allowed} = Door.admit(uid(4), "dave@example.com", false)
      # * grants no platform capability
      refute match?({:ok, :admin}, Door.admit(uid(4), "dave@example.com", true))
    end

    test "a deny wins over *, over an exact entry, and is sticky until allowed again" do
      {:ok, _} = Store.allow("wildcard", "*", "ops")
      {:ok, _} = Store.allow("email", "eve@example.com", "ops")
      {:ok, _} = Store.deny("email", "eve@example.com", "ops")
      assert {:error, :denied} = Door.admit(uid(5), "eve@example.com", true)

      {:ok, _} = Store.deny("user_id", uid(6), "ops")
      assert {:error, :denied} = Door.admit(uid(6), "frank@example.com", true)

      {:ok, _} = Store.allow("email", "eve@example.com", "ops")
      assert {:ok, :allowed} = Door.admit(uid(5), "eve@example.com", true)
    end

    test "a deny row is honoured whatever its status column says" do
      {:ok, entry} = Store.deny("email", "grace@example.com", "ops")

      import Ecto.Query, only: [from: 2]
      id = entry.id

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.ServerAllowlistEntry, where: e.id == ^id),
          set: [status: "requested"]
        )

      assert {:error, :denied} = Door.admit(uid(7), "grace@example.com", true)
    end

    test "a platform admin email cannot be denied" do
      assert {:error, :platform_admin} = Store.deny("email", "ops@example.com", "ops")
      assert {:error, :wildcard_cannot_be_denied} = Store.deny("wildcard", "*", "ops")
    end

    test "a request admits nobody until resolved" do
      {:ok, :created, req} = Store.request("grace@example.com", uid(1))
      assert req.status == "requested"
      assert {:error, :not_allowed} = Door.admit(uid(7), "grace@example.com", true)
      refute Door.email_admitted?("grace@example.com")

      {:ok, entry} = Store.resolve(req.id, :allow, uid(1))
      assert entry.status == "allowed"
      assert {:ok, :allowed} = Door.admit(uid(7), "grace@example.com", true)
      assert Door.email_admitted?("grace@example.com")

      # requesting again for an address that already has its answer changes
      # nothing, and says so — nobody new is waiting at the door
      {:ok, :existing, same} = Store.request("grace@example.com", uid(1))
      assert same.id == entry.id
    end

    test "rejecting a request removes it" do
      {:ok, :created, req} = Store.request("heidi@example.com", uid(1))
      assert :ok = Store.resolve(req.id, :reject, uid(1))
      assert Store.requests() == []
    end
  end

  describe "admit_identity/2" do
    test "wraps the verdict for a provider and audits a refusal" do
      handler = "door-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :door, :refused],
        fn _e, _m, meta, _c -> send(parent, {:refused, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, {:door, :not_allowed}} =
               Door.admit_identity(uid(9), %{email: "ivan@example.com", verified: true})

      assert_receive {:refused, %{reason: :not_allowed, email: "ivan@example.com"}}

      assert {:ok, :admin} = Door.admit_identity(uid(1), %{email: "ops@example.com"})
    end
  end

  describe "reconcile/0 — the door outlives nothing" do
    defp known_person(n, opts \\ []) do
      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: uid(n),
          provider: "github",
          email: Keyword.get(opts, :email, "person#{n}@example.com"),
          verified: Keyword.get(opts, :verified, true),
          name: nil
        })

      user
    end

    defp session_for(user) do
      {:ok, session} =
        Sanctum.Session.create(
          Sanctum.Context.build(
            user_id: user.id,
            email: user.email,
            provider: "github",
            authenticated: true,
            permissions: [:read]
          )
        )

      session
    end

    test "closing * ejects the strangers it admitted, and nobody else" do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      stranger = known_person(20)
      operator = known_person(21, email: "ops@example.com")

      stranger_session = session_for(stranger)
      operator_session = session_for(operator)

      assert {:ok, _} = Sanctum.Session.get(stranger_session.token)
      assert {:ok, _} = Sanctum.Session.get(operator_session.token)

      :ok = Store.remove(wildcard.id)

      # `*` names nobody, so there is no entry to read the ejected off —
      # the door is re-asked about everyone instead.
      assert {:ok, 1} = Door.reconcile()

      assert {:error, :invalid_session} = Sanctum.Session.get(stranger_session.token)
      assert {:ok, _} = Sanctum.Session.get(operator_session.token)
    end

    test "the keys the door issued go with the sessions" do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      stranger = known_person(24)

      tenant = Sanctum.TestContext.local()
      ctx = %{tenant | user_id: stranger.id, email: stranger.email}
      {:ok, key} = Sanctum.ApiKey.create(ctx, %{name: "stranger-key"})

      assert Enum.any?(elem(Sanctum.ApiKey.list(ctx), 1), &(&1.name == "stranger-key"))

      :ok = Store.remove(wildcard.id)
      assert {:ok, 1} = Door.reconcile()

      # A key minted while the door was open is a credential the door issued;
      # it must not outlive the entry that admitted its holder.
      assert {:error, _} = Sanctum.ApiKey.validate(key.api_key)
    end

    test "an issuer that proves nothing about the email keeps its user_id seat" do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      {:ok, _} = Store.allow("user_id", uid(22), "ops")

      # `users.email_verified` is NULL when the issuer omitted the claim.
      # Reading that as `false` rather than `:unknown` would eject them here.
      silent = known_person(22, verified: nil)
      assert silent.email_verified == nil

      session = session_for(silent)
      :ok = Store.remove(wildcard.id)

      assert {:ok, 0} = Door.reconcile()
      assert {:ok, _} = Sanctum.Session.get(session.token)
    end

    test "ejecting is not denying: standing survives" do
      {:ok, wildcard} = Store.allow("wildcard", "*", "ops")
      stranger = known_person(23)
      :ok = Store.remove(wildcard.id)

      assert {:ok, 1} = Door.reconcile()

      {:ok, after_eject} = Sanctum.Tenancy.Users.get(stranger.id)
      assert after_eject.status == "active"
      assert after_eject.denied_at == nil
    end
  end
end
