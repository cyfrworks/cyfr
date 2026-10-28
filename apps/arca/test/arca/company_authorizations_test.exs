# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CompanyAuthorizationsTest do
  @moduledoc """
  A person's company sign-in: one row per person, read by its primary key
  by the platform's actor or the person, written by the platform's actor
  alone. A binding under the configuration the person's row names
  refreshes it for the same subject and is refused for another; under
  another configuration, or none, it replaces the row; a subject another
  person holds under the same configuration is refused by the unique
  index. The caller's `verify:` runs first, under the person's lock, and
  its refusal writes nothing. The row goes with the person.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.CompanyAuthorizations
  alias Arca.Schemas.{CompanyAuthorization, User}

  @oidc ~s(["oidc","https://idp.example.com","cid"])
  @other ~s(["oidc","https://idp.example.com","another-client"])

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  defp person! do
    now = DateTime.utc_now()

    {:ok, person} =
      Arca.Test.People.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil
      )

    person.id
  end

  defp bind(user_id, configuration, subject, verify \\ fn -> :ok end) do
    CompanyAuthorizations.bind(
      server(),
      %{user_id: user_id, configuration: configuration, subject: subject},
      verify: verify
    )
  end

  defp row(user_id), do: Arca.Repo.get(CompanyAuthorization, user_id)

  test "a first binding is the person's row, read by the platform's actor and by the person alone" do
    user_id = person!()
    assert {:ok, :bound} = bind(user_id, @oidc, "sub-1")

    assert {:ok, %{user_id: ^user_id, configuration: @oidc, subject: "sub-1", authorized_at: at}} =
             CompanyAuthorizations.get(server(), user_id)

    assert %DateTime{} = at

    assert {:ok, %{subject: "sub-1"}} =
             CompanyAuthorizations.get(%Prima.Actor{user_id: user_id}, user_id)

    assert {:error, :cross_tenant} =
             CompanyAuthorizations.get(%Prima.Actor{user_id: person!()}, user_id)

    assert {:error, :not_found} = CompanyAuthorizations.get(server(), person!())
  end

  test "only the platform's own actor binds" do
    user_id = person!()

    assert {:error, :cross_tenant} =
             CompanyAuthorizations.bind(
               %Prima.Actor{user_id: user_id},
               %{user_id: user_id, configuration: @oidc, subject: "sub-1"},
               verify: fn -> :ok end
             )

    assert row(user_id) == nil
  end

  test "the same configuration and subject refreshes authorized_at, and another subject is refused" do
    user_id = person!()
    {:ok, :bound} = bind(user_id, @oidc, "sub-1")
    past = DateTime.add(DateTime.utc_now(), -86_400, :second)

    {1, _} =
      Arca.Repo.update_all(from(c in CompanyAuthorization, where: c.user_id == ^user_id),
        set: [authorized_at: past]
      )

    assert {:ok, :refreshed} = bind(user_id, @oidc, "sub-1")
    assert DateTime.compare(row(user_id).authorized_at, past) == :gt

    assert {:error, :subject_bound} = bind(user_id, @oidc, "sub-2")
    assert %{subject: "sub-1"} = row(user_id)
  end

  test "another configuration replaces the row" do
    user_id = person!()
    {:ok, :bound} = bind(user_id, @oidc, "sub-1")

    assert {:ok, :bound} = bind(user_id, @other, "sub-9")
    assert %{configuration: @other, subject: "sub-9"} = row(user_id)

    assert Arca.Repo.aggregate(
             from(c in CompanyAuthorization, where: c.user_id == ^user_id),
             :count
           ) == 1
  end

  test "a subject another person holds under the same configuration is refused, and under another it binds" do
    holder = person!()
    {:ok, :bound} = bind(holder, @oidc, "shared")
    user_id = person!()

    assert {:error, :subject_bound} = bind(user_id, @oidc, "shared")
    assert row(user_id) == nil
    assert {:ok, :bound} = bind(user_id, @other, "shared")
  end

  test "a refusal from verify: writes nothing, and verify runs before any row is read" do
    user_id = person!()
    {:ok, :bound} = bind(user_id, @oidc, "sub-1")
    before = row(user_id)

    assert {:error, :session_ended} =
             bind(user_id, @other, "sub-2", fn -> {:error, :session_ended} end)

    assert row(user_id) == before
  end

  test "the row goes with the person's users row" do
    user_id = person!()
    {:ok, :bound} = bind(user_id, @oidc, "sub-1")
    {1, _} = Arca.Repo.delete_all(from(u in User, where: u.id == ^user_id))
    assert row(user_id) == nil
  end
end

defmodule Arca.CompanyAuthorizationsRaceTest do
  @moduledoc """
  Two people bound to one subject under one configuration at once, on two
  real connections outside the sandbox. Neither reads the other's row:
  the unique index on configuration and subject decides, and exactly one
  binding stands. On PostgreSQL the second binding runs whole while the
  first's transaction is open, and the first's insert then finds the
  subject taken; on SQLite the second waits at its transaction's write
  lock until the first commits.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{CompanyAuthorizations, ControlPlane}
  alias Arca.Schemas.{CellLease, CompanyAuthorization, User}
  alias Ecto.Adapters.SQL.Sandbox

  @configuration ~s(["workos","org_race","conn_race"])
  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    hold_slot!()
    first = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    second = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          from(c in CompanyAuthorization, where: c.user_id in ^[first, second])
        )

        Arca.Repo.delete_all(from(u in User, where: u.id in ^[first, second]))
      end)
    end)

    unboxed(fn ->
      now = DateTime.utc_now()

      for id <- [first, second] do
        {:ok, _} =
          Arca.Test.People.mint(
            server(),
            %{id: id, first_seen_at: now, last_seen_at: now, created_at: now, updated_at: now},
            nil
          )
      end
    end)

    {:ok, first: first, second: second}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the lease row, the process-wide standing and the
  # claim switch are given back after the case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end

  defp bind(user_id, verify) do
    unboxed(fn ->
      CompanyAuthorizations.bind(
        server(),
        %{user_id: user_id, configuration: @configuration, subject: "prof_shared"},
        verify: verify
      )
    end)
  end

  test "two bindings of one subject at once: the unique index decides", %{
    first: first,
    second: second
  } do
    test = self()

    held =
      Task.async(fn ->
        bind(first, fn ->
          send(test, :first_open)

          receive do
            :go -> :ok
          end
        end)
      end)

    assert_receive :first_open, 5_000
    other = Task.async(fn -> bind(second, fn -> :ok end) end)

    {first_answer, second_answer} =
      if postgres?() do
        second_answer = Task.await(other, 25_000)
        send(held.pid, :go)
        {Task.await(held, 25_000), second_answer}
      else
        refute Task.yield(other, 300), "the second binding ran inside the first's write lock"
        send(held.pid, :go)
        {Task.await(held, 25_000), Task.await(other, 25_000)}
      end

    assert Enum.sort([first_answer, second_answer]) == [{:error, :subject_bound}, {:ok, :bound}]

    rows =
      unboxed(fn ->
        Arca.Repo.all(
          from(c in CompanyAuthorization,
            where: c.configuration == ^@configuration and c.subject == "prof_shared",
            select: c.user_id
          )
        )
      end)

    winner = if first_answer == {:ok, :bound}, do: first, else: second
    assert rows == [winner]
  end
end
