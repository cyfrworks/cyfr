# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.ArchiveTest do
  @moduledoc """
  Archiving is one chokepoint: whichever path archives an athanor — a
  member's `athanor.archive`, the last member leaving, a person being
  denied — its API keys are revoked, what runs in it is cancelled as the
  server (its runners killed through their worker service) and its
  members are told.
  """
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @reference "reagent:local.archive-hang:1.0.0"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "archive_#{System.unique_integer([:positive])}")
    keys = [:workers, :base_path]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :workers, [ScriptedWorker])
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    start_supervised!({ScriptedWorker, ref: @reference, script: [:hang, :hang, :hang]})

    # Who each cancel ran as.
    test = self()
    handler = "archive-cancel-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cyfr, :opus, :execute, :exception],
      fn _event, _measurements, metadata, _config ->
        if metadata[:status] == :cancelled,
          do: send(test, {:cancelled, metadata.execution_id, metadata.user_id})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp member_ctx(athanor_id, user_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # A run admitted in the athanor and dispatched to the scripted worker
  # service, whose runner attached and hangs. Answers its execution id.
  defp running!(athanor_id, user_id) do
    ctx = member_ctx(athanor_id, user_id)

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "archive-hang",
        version: "1.0.0",
        type: "reagent"
      })

    id = Cyfr.UUID7.execution_id()

    Task.start(fn ->
      Cyfr.Execution.Dispatch.run(ctx, @reference, %{},
        authority: Cyfr.Authority.zero(),
        execution_id: id
      )
    end)

    wait_until(fn -> Enum.any?(ScriptedWorker.calls(), &(&1.execution_id == id)) end, 5_000)
    id
  end

  defp cancelled?(id) do
    id in ScriptedWorker.kills() and
      match?(%{status: "cancelled"}, Arca.Repo.get(Arca.Execution, id))
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
    ctx = member_ctx(athanor_id, user_id)

    {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "k-#{System.unique_integer()}"})
    key
  end

  test "archive/2 revokes the athanor's keys, cancels its running work as the server, and tells its members" do
    n = System.unique_integer([:positive])
    owner = person(n)
    {:ok, group} = Athanors.create_group(owner.id, "Arch #{n}")
    key = key_in(group.id, owner.id)
    running = running!(group.id, owner.id)
    Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(group.id))

    assert {:ok, %{status: "archived"}} = Athanors.archive(group)

    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
    assert_receive {:cancelled, ^running, "system"}
    assert cancelled?(running)
    athanor_id = group.id
    assert_receive {:notify, ^athanor_id, :athanor_changed, _}
  end

  test "the last member leaving a group archives it the same way" do
    n = System.unique_integer([:positive])
    owner = person(n)
    {:ok, group} = Athanors.create_group(owner.id, "Leave #{n}")
    key = key_in(group.id, owner.id)
    running = running!(group.id, owner.id)

    :ok = Members.remove_member(group, user_id: owner.id)

    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(key, [])
    assert_receive {:cancelled, ^running, "system"}
    assert cancelled?(running)
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
    personal_run = running!(personal.id, u.id)
    alone_run = running!(alone.id, u.id)

    assert {:ok, %{status: "denied"}} = Users.deny(u)

    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)
    assert {:ok, %{status: "archived"}} = Athanors.get(alone.id)
    assert {:ok, %{status: "active"}} = Athanors.get(shared.id)
    assert {:error, :revoked} = Sanctum.ApiKey.validate(personal_key, [])
    assert {:error, :revoked} = Sanctum.ApiKey.validate(alone_key, [])

    assert_receive {:cancelled, ^personal_run, "system"}
    assert_receive {:cancelled, ^alone_run, "system"}
    assert cancelled?(personal_run) and cancelled?(alone_run)
  end
end
