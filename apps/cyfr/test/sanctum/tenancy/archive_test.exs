# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.ArchiveTest do
  @moduledoc """
  Archiving is one chokepoint: whichever path archives an athanor — a
  member's `athanor.archive`, the last member leaving, a person being
  denied — its API keys are revoked, what runs in it is cancelled and its
  members are told.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  # An engine that remembers what it was asked to cancel.
  defmodule FakeEngine do
    def ready?, do: true
    def run_root(_ctx, _p, _r, _i, _o), do: {:error, :unused}
    def run_root_edge(_ctx, _p, _r, _i, _o), do: {:error, :unused}
    def authority_for(_ctx, _p, _r, _o), do: {:error, :unused}
    def subscribe_events(_e, _c), do: :ok
    def unsubscribe_events(_e, _c), do: :ok
    def events_since(_e, _s, _a), do: []
    def cancel_for_restart(_ctx, _e, _p), do: {:ok, %{}}
    def get(_ctx, _e), do: {:error, :not_found}

    def list(ctx, opts) do
      send(:archive_test_probe, {:list, ctx.athanor_id, opts})
      {:ok, [%{id: "exec_" <> ctx.athanor_id}]}
    end

    def cancel(ctx, id) do
      send(:archive_test_probe, {:cancel, ctx.athanor_id, ctx.user_id, ctx.auth_method, id})
      {:ok, %{cancelled: true, execution_id: id}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:cyfr, :execution_impl)
    Application.put_env(:cyfr, :execution_impl, FakeEngine)
    Process.register(self(), :archive_test_probe)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :execution_impl, prev),
        else: Application.delete_env(:cyfr, :execution_impl)
    end)

    :ok
  end

  defp person(n) do
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|arch-#{n}",
        provider: "github",
        email: "arch#{n}@example.com",
        verified: true
      })

    user
  end

  defp key_in(athanor_id, user_id) do
    ctx =
      Context.build(
        user_id: user_id,
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "k-#{System.unique_integer()}"})
    key
  end

  test "archive/2 revokes the athanor's keys, cancels its running work as the server, and tells its members" do
    n = System.unique_integer([:positive])
    owner = person(n)
    {:ok, group} = Athanors.create_group(owner.id, "Arch #{n}")
    key = key_in(group.id, owner.id)
    Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(group.id))

    assert {:ok, %{status: "archived"}} = Athanors.archive(group)

    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
    assert_receive {:list, athanor_id, [status: :running, limit: 500]}
    assert athanor_id == group.id
    assert_receive {:cancel, ^athanor_id, "system", :system, "exec_" <> _}
    assert_receive {:notify, ^athanor_id, :athanor_changed, _}
  end

  test "the last member leaving a group archives it the same way; Home is never archived" do
    n = System.unique_integer([:positive])
    owner = person(n)
    {:ok, group} = Athanors.create_group(owner.id, "Leave #{n}")
    key = key_in(group.id, owner.id)

    :ok = Members.remove_member(group, user_id: owner.id)

    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
    assert_receive {:cancel, athanor_id, "system", :system, _}
    assert athanor_id == group.id

    # Home closes the same way — keys revoked, work cancelled — and its
    # successor is minted rather than the row reopened.
    home = Athanors.home!()
    home_key = key_in(home.id, owner.id)
    {:ok, _} = Members.ensure(owner.id, scope: "athanor", athanor_id: home.id)
    :ok = Members.remove_member(home, user_id: owner.id)

    assert {:ok, %{status: "archived", home: true}} = Athanors.get(home.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(home_key, [])
    assert {:error, :not_found} = Athanors.home()
    assert {:ok, successor} = Athanors.ensure_home()
    assert successor.id != home.id
  end

  test "denying a person archives their own athanor and the groups they were the last member of, closing both" do
    n = System.unique_integer([:positive])
    u = person(n)

    {:ok, personal} =
      Athanors.create(%{
        kind: "person",
        name: "P#{n}",
        slug: "arch-p#{n}",
        owner_user_id: u.id,
        created_by: u.id
      })

    {:ok, u} = Users.set_personal_athanor(u, personal.id)
    {:ok, alone} = Athanors.create_group(u.id, "Alone #{n}")
    other = person(n + 100_000)
    {:ok, shared} = Athanors.create_group(other.id, "Shared #{n}")
    {:ok, :added} = Members.add(shared, [user_id: u.id], other.id)
    personal_key = key_in(personal.id, u.id)
    alone_key = key_in(alone.id, u.id)

    assert {:ok, %{status: "denied"}} = Users.deny(u)

    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
    assert {:ok, %{status: "archived"}} = Athanors.get(alone.id)
    assert {:ok, %{status: "active"}} = Athanors.get(shared.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(personal_key, [])
    assert {:error, :revoked} = Sanctum.ApiKey.validate(alone_key, [])

    cancelled =
      for _ <- 1..2 do
        assert_receive {:cancel, athanor_id, "system", :system, _}
        athanor_id
      end

    assert Enum.sort(cancelled) == Enum.sort([personal.id, alone.id])
  end
end
