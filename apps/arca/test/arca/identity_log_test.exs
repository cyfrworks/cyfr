# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.IdentityLogTest do
  @moduledoc """
  The directory's store: one log per identifier, serialized by expected
  head for a rotation and by expected revision for a recovery, a request
  id answered with its recorded outcome, refusal included, and quotas
  decided under the store's one lock, the recovery reserve kept for
  recoveries.
  """

  # Every write takes the directory's one usage row; running alone keeps a
  # case's quota arithmetic its own.
  use ExUnit.Case, async: false

  alias Arca.IdentityLog

  @policy %{max_identities: 100_000, log_bytes: 1_073_741_824, recovery_reserve_bytes: 10_485_760}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    :ok
  end

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

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
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  defp genesis! do
    entry = "genesis-#{System.unique_integer()}"
    identifier = "per_" <> Prima.Digest.sha256_hex(entry)
    hash = "sha256:" <> Prima.Digest.sha256_hex(entry)

    {:ok, row} =
      IdentityLog.register(
        server(),
        %{identifier: identifier, entry: entry, entry_hash: hash},
        @policy
      )

    {identifier, row}
  end

  defp rotate(identifier, prev, policy \\ @policy) do
    IdentityLog.append(
      server(),
      identifier,
      %{
        entry: "rotate-#{System.unique_integer()}",
        entry_hash: digest("rotate"),
        prev_hash: prev
      },
      policy
    )
  end

  defp recover(identifier, prev, attrs, policy \\ @policy) do
    IdentityLog.recover(
      server(),
      identifier,
      Map.merge(
        %{
          entry: "recover-#{System.unique_integer()}",
          entry_hash: digest("recover"),
          prev_hash: prev,
          request_id: "req_#{System.unique_integer([:positive])}",
          request_digest: digest("request"),
          expected_revision: 0
        },
        attrs
      ),
      policy
    )
  end

  describe "register/3" do
    test "writes the genesis at position 0, and the same genesis again is one registration" do
      entry = "genesis-#{System.unique_integer()}"
      identifier = "per_" <> Prima.Digest.sha256_hex(entry)

      attrs = %{
        identifier: identifier,
        entry: entry,
        entry_hash: "sha256:" <> Prima.Digest.sha256_hex(entry)
      }

      assert {:ok, %{seq: 0, kind: "genesis"} = first} =
               IdentityLog.register(server(), attrs, @policy)

      assert {:ok, ^first} = IdentityLog.register(server(), attrs, @policy)
      assert {:ok, [^first]} = IdentityLog.entries(server(), identifier)
      assert {:ok, %{identities: 1}} = IdentityLog.usage(server())

      assert {:error, :conflict} =
               IdentityLog.register(server(), %{attrs | entry: "other bytes"}, @policy)
    end

    test "refuses a new genesis at capacity, while an existing one is still answered" do
      {identifier, row} = genesis!()
      full = %{@policy | max_identities: 1}

      assert {:ok, ^row} =
               IdentityLog.register(
                 server(),
                 %{identifier: identifier, entry: row.entry, entry_hash: row.entry_hash},
                 full
               )

      entry = "genesis-#{System.unique_integer()}"

      assert {:error, {:capacity, :identities}} =
               IdentityLog.register(
                 server(),
                 %{
                   identifier: "per_" <> Prima.Digest.sha256_hex(entry),
                   entry: entry,
                   entry_hash: "sha256:" <> Prima.Digest.sha256_hex(entry)
                 },
                 full
               )
    end

    test "refuses an entry past the size bound and a malformed policy" do
      entry = String.duplicate("x", Prima.Identity.max_entry_bytes() + 1)

      attrs = %{
        identifier: "per_" <> Prima.Digest.sha256_hex(entry),
        entry: entry,
        entry_hash: digest("big")
      }

      assert {:error, :entry_too_large} = IdentityLog.register(server(), attrs, @policy)

      assert {:error, :invalid_policy} =
               IdentityLog.register(server(), attrs, %{
                 @policy
                 | recovery_reserve_bytes: @policy.log_bytes
               })
    end
  end

  describe "append/4" do
    test "extends the head it names; two appends on one head, one wins and one is stale" do
      {identifier, genesis} = genesis!()

      assert {:ok, %{seq: 1, prev_hash: prev}} = rotate(identifier, genesis.entry_hash)
      assert prev == genesis.entry_hash
      assert {:error, :stale} = rotate(identifier, genesis.entry_hash)
      assert {:ok, entries} = IdentityLog.entries(server(), identifier)
      assert length(entries) == 2
    end

    test "an unknown identifier is not found, and a rotation may not spend the recovery reserve" do
      assert {:error, :not_found} = rotate("per_" <> String.duplicate("0", 64), digest("x"))

      {identifier, genesis} = genesis!()
      {:ok, %{log_bytes: used}} = IdentityLog.usage(server())
      tight = %{@policy | log_bytes: used + 20, recovery_reserve_bytes: 10}

      assert {:error, {:capacity, :log_bytes}} = rotate(identifier, genesis.entry_hash, tight)
    end
  end

  describe "recover/4" do
    test "applies against the current revision; the same request answers its recorded outcome" do
      {identifier, genesis} = genesis!()
      {:ok, rotated} = rotate(identifier, genesis.entry_hash)
      request = %{request_id: "req_first", request_digest: digest("first"), expected_revision: 0}

      # Online state moved (a rotation) and the recovery still applies at
      # the head, against the revision it expected.
      assert {:ok, %{kind: "recover", seq: 2} = accepted} =
               recover(identifier, rotated.entry_hash, request)

      # The same request again, whatever the head is now: its recorded outcome.
      assert {:ok, ^accepted} = recover(identifier, accepted.entry_hash, request)
      assert {:ok, ^accepted} = IdentityLog.outcome(server(), identifier, "req_first")
    end

    test "a stale revision is refused and recorded; a retry answers the same refusal" do
      {identifier, genesis} = genesis!()
      {:ok, first} = recover(identifier, genesis.entry_hash, %{expected_revision: 0})

      stale = %{request_id: "req_stale", request_digest: digest("stale"), expected_revision: 0}
      assert {:error, :stale_policy} = recover(identifier, first.entry_hash, stale)

      assert {:ok, %{outcome: "stale_policy", seq: nil, outcome_body: body}} =
               IdentityLog.outcome(server(), identifier, "req_stale")

      assert %{"revision" => 1, "expected_revision" => 0} = Jason.decode!(body)

      # Retried after the log moved on, still the recorded refusal.
      {:ok, _} = rotate(identifier, first.entry_hash)
      assert {:error, :stale_policy} = recover(identifier, first.entry_hash, stale)
      assert {:ok, entries} = IdentityLog.entries(server(), identifier)
      assert Enum.map(entries, & &1.kind) == ["genesis", "recover", "rotate"]
    end

    test "the same request id with another digest is refused" do
      {identifier, genesis} = genesis!()
      {:ok, _} = recover(identifier, genesis.entry_hash, %{request_id: "req_reused"})

      assert {:error, :request_id_reused} =
               recover(identifier, genesis.entry_hash, %{
                 request_id: "req_reused",
                 request_digest: digest("changed")
               })
    end

    test "a head that moved while the revision stands records nothing; the caller rebuilds" do
      {identifier, genesis} = genesis!()
      {:ok, rotated} = rotate(identifier, genesis.entry_hash)

      assert {:error, :stale} =
               recover(identifier, genesis.entry_hash, %{request_id: "req_rebuild"})

      assert {:error, :not_found} = IdentityLog.outcome(server(), identifier, "req_rebuild")
      assert {:ok, _} = recover(identifier, rotated.entry_hash, %{request_id: "req_rebuild"})
    end

    test "a recovery may spend the reserve a rotation may not" do
      {identifier, genesis} = genesis!()
      {:ok, %{log_bytes: used}} = IdentityLog.usage(server())
      tight = %{@policy | log_bytes: used + 64, recovery_reserve_bytes: 60}

      assert {:error, {:capacity, :log_bytes}} = rotate(identifier, genesis.entry_hash, tight)
      assert {:ok, %{kind: "recover"}} = recover(identifier, genesis.entry_hash, %{}, tight)
    end
  end

  test "reads page the log, and only the platform's actor reads or writes" do
    {identifier, genesis} = genesis!()
    {:ok, one} = rotate(identifier, genesis.entry_hash)
    {:ok, two} = rotate(identifier, one.entry_hash)

    assert {:ok, [^genesis, ^one]} = IdentityLog.entries(server(), identifier, limit: 2)
    assert {:ok, [^two]} = IdentityLog.entries(server(), identifier, after: 1)
    assert {:ok, ^two} = IdentityLog.head(server(), identifier)

    member = Prima.Actor.in_athanor("ath_test")
    assert {:error, :cross_tenant} = IdentityLog.entries(member, identifier)
    assert {:error, :cross_tenant} = IdentityLog.append(member, identifier, %{}, @policy)
  end
end

defmodule Arca.IdentityLogRaceTest do
  @moduledoc """
  Two rotations appended on one expected head at once, on real
  connections outside the sandbox: each decides under the directory's
  usage row, locked first, so the one that waits reads the head the other
  committed and is refused `:stale`. On PostgreSQL the first is held just
  before it writes its entry (a trigger waits on an advisory lock the test
  holds) and the second blocks on the usage row; on SQLite both queue
  behind a transaction holding the write lock and run one after the other.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, IdentityLog}
  alias Arca.Schemas.{CellLease, IdentityLogEntry, ServerMeta}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_004
  @usage_key "directory_usage"
  @policy %{max_identities: 100_000, log_bytes: 1_073_741_824, recovery_reserve_bytes: 10_485_760}

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  setup do
    hold_slot!()
    entry = "genesis-race-#{System.unique_integer()}"
    identifier = "per_" <> Prima.Digest.sha256_hex(entry)

    # The directory's usage is one committed row every suite reads: it is
    # put back as it was.
    usage = unboxed(fn -> Arca.Repo.one(where(ServerMeta, key: @usage_key)) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(IdentityLogEntry, identifier: ^identifier))
        Arca.Repo.delete_all(where(ServerMeta, key: @usage_key))

        if usage do
          Arca.Repo.insert_all(ServerMeta, [
            %{key: usage.key, value: usage.value, updated_at: usage.updated_at}
          ])
        end
      end)
    end)

    {:ok, genesis} =
      unboxed(fn ->
        IdentityLog.register(
          server(),
          %{
            identifier: identifier,
            entry: entry,
            entry_hash: "sha256:" <> Prima.Digest.sha256_hex(entry)
          },
          @policy
        )
      end)

    {:ok, identifier: identifier, genesis: genesis}
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

  # On PostgreSQL, `backend` is blocked on a lock, at the gate (`:gate`) or
  # in a statement naming every one of `fragments`.
  defp await_wait!(backend, at, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    waiting? =
      type == "Lock" and
        case at do
          :gate -> event == "advisory"
          fragments -> event != "advisory" and Enum.all?(fragments, &String.contains?(query, &1))
        end

    cond do
      waiting? ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} is not waiting at #{inspect(at)}: #{type} #{event} #{query}")

      true ->
        retry_wait!(backend, at, tries)
    end
  end

  defp retry_wait!(backend, at, tries) do
    Process.sleep(20)
    await_wait!(backend, at, tries - 1)
  end

  # A trigger that holds a connection which set `arca_test.gate` before
  # `table`'s next `event` statement (`level` "STATEMENT") or at its next
  # row, once the row is locked (`level` "ROW"), until the test opens the
  # gate.
  defp install_gate!(table, event, level) do
    unboxed(fn ->
      Arca.Repo.query!("""
      CREATE OR REPLACE FUNCTION arca_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('arca_test.gate', true) = 'on' THEN
          PERFORM pg_advisory_lock(#{@gate});
          PERFORM pg_advisory_unlock(#{@gate});
        END IF;
        IF TG_LEVEL = 'ROW' THEN RETURN NEW; END IF;
        RETURN NULL;
      END $$
      """)

      Arca.Repo.query!(
        "CREATE TRIGGER arca_test_gate BEFORE #{event} ON #{table} " <>
          "FOR EACH #{level} EXECUTE FUNCTION arca_test_gate()"
      )
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.query!("DROP TRIGGER IF EXISTS arca_test_gate ON #{table}")
        Arca.Repo.query!("DROP FUNCTION IF EXISTS arca_test_gate()")
      end)
    end)
  end

  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.query!("SELECT pg_advisory_lock($1)", [@gate])
          send(test, :gate_closed)

          receive do
            :open -> Arca.Repo.query!("SELECT pg_advisory_unlock($1)", [@gate])
          end
        end)
      end)

    assert_receive :gate_closed, 5_000
    holder
  end

  defp open_gate!(holder) do
    send(holder.pid, :open)
    Task.await(holder)
  end

  defp gated(fun) do
    Arca.Repo.query!("SELECT set_config('arca_test.gate', 'on', false)")

    try do
      fun.()
    after
      Arca.Repo.query!("SELECT set_config('arca_test.gate', '', false)")
    end
  end

  # On SQLite, a transaction holding the one write lock until released, so
  # the writers started behind it queue at their transactions' entry.
  defp hold_write_lock! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            send(test, :write_lock_held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :write_lock_held, 5_000
    holder
  end

  defp release_write_lock!(holder) do
    send(holder.pid, :release)
    Task.await(holder)
  end

  defp rotate(identifier, prev) do
    IdentityLog.append(
      server(),
      identifier,
      %{
        entry: "rotate-#{System.unique_integer()}",
        entry_hash: digest("rotate"),
        prev_hash: prev
      },
      @policy
    )
  end

  defp appender(identifier, prev, gate?) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:appender, self(), backend()})
          if gate?, do: gated(fn -> rotate(identifier, prev) end), else: rotate(identifier, prev)
        end)
      end)

    assert_receive {:appender, _, pid}, 5_000
    {task, pid}
  end

  test "two appends on one head: the one that waits reads the other's and is stale", %{
    identifier: identifier,
    genesis: genesis
  } do
    results =
      if postgres?() do
        install_gate!("identity_log_entries", "INSERT", "STATEMENT")
        gate = close_gate!()
        {first, holding} = appender(identifier, genesis.entry_hash, true)
        await_wait!(holding, :gate)

        {second, waiting} = appender(identifier, genesis.entry_hash, false)
        await_wait!(waiting, [~s("server_meta")])

        refute Task.yield(second, 300),
               "the second append decided while the first held the usage row"

        open_gate!(gate)
        assert {:ok, %{seq: 1}} = Task.await(first, 25_000)
        assert {:error, :stale} = Task.await(second, 25_000)
        :ordered
      else
        holder = hold_write_lock!()
        {first, _} = appender(identifier, genesis.entry_hash, false)
        {second, _} = appender(identifier, genesis.entry_hash, false)
        refute Task.yield(first, 300)
        refute Task.yield(second, 300)

        release_write_lock!(holder)

        Enum.sort_by(
          [Task.await(first, 25_000), Task.await(second, 25_000)],
          &match?({:ok, _}, &1)
        )
      end

    case results do
      :ordered -> :ok
      [{:error, :stale}, {:ok, %{seq: 1}}] -> :ok
    end

    assert {:ok, [_genesis, %{seq: 1}]} =
             unboxed(fn -> IdentityLog.entries(server(), identifier) end)
  end
end
