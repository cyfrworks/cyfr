# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstallationClaimsTest do
  @moduledoc """
  Who may mint the installation's first person, decided inside every
  person mint by its admission. Only setup makes the first person, who is
  written with the platform administrator's mark
  (`users.platform_admin_at`) in the mint's own transaction; every other
  admission onto an empty node is refused. Setup binds the installation
  to its first person and then opens nothing: once any person exists it
  is refused, whatever they hold, and its closure never runs.
  """

  # Takes the cell's slot; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, InstallationClaims, Users}
  alias Arca.Schemas.{CellLease, ServerMeta, User}

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()

    # The node is empty inside this test's transaction, whatever another
    # suite committed: the guard's question is about this node's people.
    Arca.Repo.delete_all(User)
    {:ok, slot: slot}
  end

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
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
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()

  defp person_attrs do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    %{
      id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      email: "first#{n}@example.com",
      email_verified: true,
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    }
  end

  # A setup mint.
  defp mint(opts \\ []) do
    Users.mint(server(), person_attrs(), Keyword.merge([admission: "setup"], opts))
  end

  # A mint under `admission`.
  defp admitted(admission, opts \\ []) do
    Users.mint(server(), person_attrs(), [admission: admission] ++ opts)
  end

  defp administrator?(user_id),
    do:
      Arca.Repo.exists?(
        from(u in User, where: u.id == ^user_id and not is_nil(u.platform_admin_at))
      )

  defp administrators,
    do: Arca.Repo.aggregate(from(u in User, where: not is_nil(u.platform_admin_at)), :count)

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp open?, do: InstallationClaims.setup(server())

  describe "the first person" do
    test "is made by setup, and holds the administrator's mark from the mint's transaction" do
      me = self()

      assert {:ok, %{id: id, admission: "setup"}} =
               mint(
                 also: fn person ->
                   send(me, {:marked, administrator?(person.id)})
                   :ok
                 end
               )

      # The closure runs after the row is written with its mark, inside
      # the transaction.
      assert_received {:marked, true}
      assert people() == 1
      assert administrator?(id)
      assert administrators() == 1
    end

    test "is refused to every other admission, and nothing is written" do
      for admission <- ~w(open remote invitation) do
        assert {:error, :not_set_up} = admitted(admission)
      end

      assert people() == 0
      assert administrators() == 0
    end

    test "is the only one marked: a later person holds no mark" do
      assert {:ok, %{id: first}} = mint()
      assert {:ok, %{id: second, admission: "open"}} = admitted("open")
      assert {:ok, %{id: third}} = admitted("remote")

      assert administrator?(first)
      refute administrator?(second)
      refute administrator?(third)
      assert administrators() == 1
    end

    test "once its mint commits, the log says so, after the boot's not-set-up line's marker" do
      marker = InstallationClaims.set_up_marker()
      assert marker == "[Cyfr] Set up:"

      # A refused mint and a closure's refusal make no first person, and
      # say nothing.
      refused =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :not_set_up} = admitted("open")
          assert {:error, :keys_unavailable} = mint(also: fn _ -> {:error, :keys_unavailable} end)
        end)

      refute refused =~ marker

      made = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _first} = mint() end)
      assert [_one] = String.split(made, marker) |> tl()

      # A later person is not the first.
      later = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _} = admitted("open") end)
      refute later =~ marker
    end

    test "a refusal of the mint's closure takes the mark back with the person" do
      assert {:error, :keys_unavailable} =
               mint(also: fn _person -> {:error, :keys_unavailable} end)

      assert people() == 0
      assert administrators() == 0
    end
  end

  describe "setup once a person exists" do
    test "opens nothing, whatever that person holds, and runs no closure" do
      me = self()
      {:ok, %{id: first}} = mint()

      assert {:error, :setup_closed} =
               mint(
                 also: fn _person ->
                   send(me, :also)
                   :ok
                 end
               )

      refute_received :also

      # A person setup did not make closes it the same.
      {:ok, _other} = admitted("open")
      assert {:error, :setup_closed} = mint()

      assert people() == 2
      assert administrator?(first)
      assert administrators() == 1
    end
  end

  describe "setup/1, the guard's answer read without its locks" do
    test "answers what a setup's mint would: the first person, then closed" do
      assert {:ok, :first} = open?()
      {:ok, _first} = mint()
      assert {:ok, :closed} = open?()
      assert {:error, :setup_closed} = mint()
    end

    test "is refused to any actor but the platform's" do
      assert {:error, :cross_tenant} = InstallationClaims.setup(%Prima.Actor{user_id: "per_x"})
    end

    test "reads and writes nothing it holds: no row is added" do
      before = people()
      assert {:ok, :first} = open?()
      assert people() == before
    end
  end

  describe "the order row" do
    test "a database without the fingerprint row raises rather than deciding unordered" do
      key = Arca.SchemaFingerprint.key()
      {1, _} = Arca.Repo.delete_all(from(m in ServerMeta, where: m.key == ^key))

      assert_raise RuntimeError, ~r/no schema fingerprint row/, fn -> mint() end
      assert people() == 0
    end
  end

  describe "the member fence" do
    test "a stale owner mints no first person and marks no one", %{slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = mint()
      assert people() == 0
      assert administrators() == 0
    end
  end
end

defmodule Arca.InstallationClaimsRaceTest do
  @moduledoc """
  Two setups at once, on two real connections outside the sandbox. Both
  decide after locking one row, the schema fingerprint's, so the one that
  waits reads what the other committed: a second setup behind the first
  is closed. On PostgreSQL the waiter blocks on that row; on SQLite at
  the lock its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, Users}
  alias Arca.Schemas.{CellLease, User}

  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    hold_slot!()
    door_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    second_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      unboxed(fn ->
        for id <- [door_id, second_id] do
          Arca.Repo.delete_all(where(User, id: ^id))
        end
      end)
    end)

    # The race is over an empty node: nothing committed may hold a person
    # when it starts.
    assert 0 == unboxed(fn -> Arca.Repo.aggregate(User, :count) end)

    {:ok, door_id: door_id, second_id: second_id}
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

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # The waiter blocks where the order row is locked.
  defp assert_waits_on_order!(task, backend) do
    if postgres?(), do: LockWait.await_lock_wait!(backend, [~s("server_meta"), "FOR UPDATE"])
    refute Task.yield(task, 300), "the waiter decided while the other side held the order row"
  end

  defp pause(test, tag) do
    fn _row ->
      send(test, {tag, :holds})

      receive do
        :go -> :ok
      end
    end
  end

  # Setup's mint of the first person `id`.
  defp door(id, opts) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    Users.mint(
      server(),
      %{
        id: id,
        email: "door#{n}@example.com",
        email_verified: true,
        first_seen_at: now,
        last_seen_at: now,
        created_at: now,
        updated_at: now
      },
      [admission: "setup"] ++ opts
    )
  end

  test "a second setup waits behind the first and is closed", %{
    door_id: id,
    second_id: second_id
  } do
    test = self()

    first = Task.async(fn -> unboxed(fn -> door(id, also: pause(test, :door)) end) end)
    assert_receive {:door, :holds}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend()})

          door(second_id, [])
        end)
      end)

    assert_receive {:second, pid}, 5_000
    assert_waits_on_order!(second, pid)

    send(first.pid, :go)
    assert {:ok, %{id: ^id}} = Task.await(first, 25_000)
    assert {:error, :setup_closed} = Task.await(second, 25_000)

    assert {1, 1} ==
             unboxed(fn ->
               {Arca.Repo.aggregate(User, :count),
                Arca.Repo.aggregate(
                  from(u in User, where: u.id == ^id and not is_nil(u.platform_admin_at)),
                  :count
                )}
             end)
  end
end
