# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpersTest do
  @moduledoc """
  The tenant backstop, read off the actor.

  `where_tenant/2` scopes to the actor's athanor and raises for one that
  carries none; `where_tenant_unless_platform/2` is the one spelling of
  the platform bypass, and it reads `scope`, which is not a wire member
  of `Cyfr.Actor` — nothing a worker returns can claim it.
  """
  use ExUnit.Case, async: true

  alias Arca.QueryHelpers

  import Ecto.Query

  defp base_query, do: from(e in Arca.Execution)

  defp in_athanor(id), do: Cyfr.Actor.in_athanor(id)
  defp platform, do: Cyfr.Actor.system()

  describe "where_tenant/2" do
    test "applies the athanor filter" do
      query = QueryHelpers.where_tenant(base_query(), in_athanor("ath_1"))

      assert length(query.wheres) == 1
    end

    test "a fully named athanor-scope actor passes unchanged" do
      actor = Arca.Test.Actor.local()
      query = QueryHelpers.where_tenant(base_query(), actor)
      assert length(query.wheres) == 1
    end
  end

  describe "where_tenant/2 athanor-less fail-closed backstop" do
    test "an actor with a nil athanor raises" do
      actor = %Cyfr.Actor{athanor_id: nil, authenticated: true}

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        apply(QueryHelpers, :where_tenant, [base_query(), actor])
      end
    end

    test "an actor with an empty-string athanor raises, exactly as nil does" do
      # "" is an identity that was never resolved. Admitting it would
      # filter on athanor_id == "", match nothing, and answer an ordinary
      # empty result — a refusal turned into silence.
      actor = %Cyfr.Actor{athanor_id: "", authenticated: true}

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        apply(QueryHelpers, :where_tenant, [base_query(), actor])
      end
    end

    test "a platform-scope actor with no athanor raises too" do
      # Platform readers that cross athanors use where_tenant_unless_platform/2;
      # a platform task working inside one athanor carries that athanor.
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        apply(QueryHelpers, :where_tenant, [base_query(), platform()])
      end
    end

    test "a plain map carrying an athanor is not an actor: no head matches it" do
      assert_raise FunctionClauseError, fn ->
        apply(QueryHelpers, :where_tenant, [base_query(), %{athanor_id: "ath_1", user_id: "u"}])
      end
    end
  end

  describe "where_tenant_unless_platform/2" do
    test "a platform-scope actor reads unfiltered, across every athanor" do
      query = QueryHelpers.where_tenant_unless_platform(base_query(), platform())
      assert query.wheres == []
    end

    test "an athanor-scope actor on the same function is scoped" do
      query = QueryHelpers.where_tenant_unless_platform(base_query(), in_athanor("ath_1"))
      assert length(query.wheres) == 1
    end

    test "the server's own actor narrowed to one athanor gives up the cross-tenant read" do
      narrowed = %{platform() | athanor_id: "ath_1", scope: :athanor}

      query = QueryHelpers.where_tenant_unless_platform(base_query(), narrowed)
      assert length(query.wheres) == 1
    end

    test "a plain map is not an actor here either, whatever scope it claims" do
      assert_raise FunctionClauseError, fn ->
        apply(QueryHelpers, :where_tenant_unless_platform, [
          base_query(),
          %{athanor_id: "ath_1", scope: :platform}
        ])
      end
    end
  end

  describe "stamp_tenant!/2" do
    test "stamps the actor's athanor and raises for one that carries none" do
      assert %{athanor_id: "ath_1"} = QueryHelpers.stamp_tenant!(in_athanor("ath_1"), %{})

      for unresolved <- [%Cyfr.Actor{athanor_id: nil}, %Cyfr.Actor{athanor_id: ""}] do
        assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
          QueryHelpers.stamp_tenant!(unresolved, %{})
        end
      end
    end
  end

  describe "no_athanor!/1" do
    test "is the raise a ! entry point owes an actor with no athanor" do
      assert_raise ArgumentError, ~r/a resolved athanor is required/, fn ->
        QueryHelpers.no_athanor!("Arca.Thing.write!/2")
      end
    end
  end

  describe "where_athanor/2" do
    test "filters by a bare athanor id" do
      query = QueryHelpers.where_athanor(base_query(), "ath_1")
      assert length(query.wheres) == 1
    end

    test "nil and empty raise" do
      assert_raise ArgumentError, fn -> QueryHelpers.where_athanor(base_query(), nil) end
      assert_raise ArgumentError, fn -> QueryHelpers.where_athanor(base_query(), "") end
    end
  end

  describe "maybe_put/3" do
    test "adds key-value when value is non-nil" do
      assert QueryHelpers.maybe_put([], :limit, 10) == [limit: 10]
    end

    test "returns list unchanged when value is nil" do
      assert QueryHelpers.maybe_put([limit: 10], :status, nil) == [limit: 10]
    end

    test "overwrites existing key" do
      assert QueryHelpers.maybe_put([limit: 10], :limit, 20) == [limit: 20]
    end

    test "works with empty list and nil" do
      assert QueryHelpers.maybe_put([], :key, nil) == []
    end
  end

  describe "for_update/1" do
    test "locks the rows it reads on PostgreSQL, and leaves SQLite's query untouched" do
      query = from(c in Arca.Schemas.JobClaim, where: c.kind == "bootstrap")
      locked = QueryHelpers.for_update(query)
      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Arca.Repo, locked)

      case Arca.Repo.adapter() do
        Ecto.Adapters.Postgres ->
          assert sql =~ ~r/FOR UPDATE$/

        Ecto.Adapters.SQLite3 ->
          # SQLite's adapter raises on any lock clause; the immediate
          # transaction around the read is the lock there.
          assert locked == query
          refute sql =~ "FOR UPDATE"
      end
    end

    test "a bare schema is a queryable it can lock" do
      locked = QueryHelpers.for_update(Arca.Schemas.JobClaim)
      assert {_sql, []} = Ecto.Adapters.SQL.to_sql(:all, Arca.Repo, locked)
    end
  end

  describe "for_share/1" do
    test "shares the rows it reads on PostgreSQL, and leaves SQLite's query untouched" do
      query = from(c in Arca.Schemas.JobClaim, where: c.kind == "bootstrap")
      shared = QueryHelpers.for_share(query)
      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Arca.Repo, shared)

      case Arca.Repo.adapter() do
        Ecto.Adapters.Postgres ->
          assert sql =~ ~r/FOR SHARE$/
          refute sql =~ "FOR UPDATE"

        Ecto.Adapters.SQLite3 ->
          assert shared == query
          refute sql =~ "FOR SHARE"
      end
    end

    test "a bare schema is a queryable it can share" do
      shared = QueryHelpers.for_share(Arca.Schemas.JobClaim)
      assert {_sql, []} = Ecto.Adapters.SQL.to_sql(:all, Arca.Repo, shared)
    end
  end
end

defmodule Arca.LockingTransactionTest do
  @moduledoc """
  `Arca.Repo.locking_transaction/2` with `Arca.QueryHelpers.for_update/1`,
  and `Arca.Repo.read_transaction/1` with `for_share/1`, under
  real connections, outside the sandbox: inside it one shared connection
  would serialize the transactions the test is about.

  PostgreSQL's loser opens its transaction at once and waits on the row;
  SQLite's waits at its own BEGIN, since the winner's immediate
  transaction holds the one write lock. Either way the loser acts only on
  what the winner committed, and reads the database's clock after its
  wait.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.JobClaim
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    key = "lock-#{System.unique_integer([:positive])}"
    {:ok, claim} = unboxed(fn -> Arca.JobClaims.claim("retention", key, "boot_lock", 60_000) end)
    on_exit(fn -> unboxed(fn -> Arca.Repo.delete_all(where(JobClaim, key: ^key)) end) end)
    {:ok, claim: claim}
  end

  defp locked_detail(claim) do
    from(c in JobClaim, where: c.id == ^claim.id, select: c.detail)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  test "answers what the function answers, and a rollback commits nothing", %{claim: claim} do
    assert {:ok, nil} =
             unboxed(fn -> Arca.Repo.locking_transaction(fn -> locked_detail(claim) end) end)

    assert {:error, :refused} =
             unboxed(fn ->
               Arca.Repo.locking_transaction(fn ->
                 Arca.Repo.update_all(where(JobClaim, id: ^claim.id), set: [detail: "moved"])
                 Arca.Repo.rollback(:refused)
               end)
             end)

    assert {:ok, nil} =
             unboxed(fn -> Arca.Repo.locking_transaction(fn -> locked_detail(claim) end) end)
  end

  test "runs a multi as the same transaction", %{claim: claim} do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:before, fn _repo, _ -> {:ok, locked_detail(claim)} end)
      |> Ecto.Multi.update_all(:write, where(JobClaim, id: ^claim.id), set: [detail: "multi"])

    assert {:ok, %{before: nil, write: {1, _}}} =
             unboxed(fn -> Arca.Repo.locking_transaction(multi) end)
  end

  test "the loser waits for the winner's commit and acts only on what it committed", %{
    claim: claim
  } do
    test = self()

    winner =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            nil = locked_detail(claim)
            send(test, :holding)

            receive do
              :commit -> :ok
            end

            Arca.Repo.update_all(where(JobClaim, id: ^claim.id), set: [detail: "winner"])
            Arca.ServerMetaStorage.now!()
          end)
        end)
      end)

    assert_receive :holding, 5_000

    loser =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            send(test, :loser_began)
            detail = locked_detail(claim)
            {detail, Arca.ServerMetaStorage.now!()}
          end)
        end)
      end)

    case Arca.Repo.adapter() do
      Ecto.Adapters.Postgres ->
        # The transaction is open; the row is what it waits on.
        assert_receive :loser_began, 5_000

      Ecto.Adapters.SQLite3 ->
        # The one write lock is the winner's, so the loser's BEGIN waits.
        refute_receive :loser_began, 300
    end

    refute Task.yield(loser, 300), "the loser read the row while the winner held it"

    send(winner.pid, :commit)
    assert {:ok, committed_at} = Task.await(winner, 25_000)
    assert {:ok, {"winner", read_at}} = Task.await(loser, 25_000)

    # SQLite's loser began only once the winner's transaction had ended.
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3, do: assert_received(:loser_began)

    # The loser's clock reading is its own, taken after the wait.
    assert DateTime.compare(read_at, committed_at) in [:gt, :eq]
  end

  defp shared_detail(claim) do
    from(c in JobClaim, where: c.id == ^claim.id, select: c.detail)
    |> QueryHelpers.for_share()
    |> Arca.Repo.one()
  end

  test "a read transaction answers what the function answers, and writes nothing it rolls back",
       %{claim: claim} do
    assert {:ok, nil} =
             unboxed(fn -> Arca.Repo.read_transaction(fn -> shared_detail(claim) end) end)

    assert {:error, :refused} =
             unboxed(fn ->
               Arca.Repo.read_transaction(fn ->
                 _ = shared_detail(claim)
                 Arca.Repo.rollback(:refused)
               end)
             end)
  end

  test "a read transaction waits behind no other reader, and on SQLite behind no writer", %{
    claim: claim
  } do
    test = self()

    # A writer holding its transaction open: SQLite's immediate one holds
    # the one write lock; PostgreSQL's holds the row it wrote.
    writer =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            Arca.Repo.update_all(where(JobClaim, id: ^claim.id), set: [detail: "held"])
            send(test, :writing)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :writing, 5_000

    # A plain read in a read transaction reads the last commit at once on
    # both: SQLite's deferred transaction takes no write lock.
    plain = fn ->
      from(c in JobClaim, where: c.id == ^claim.id, select: c.detail) |> Arca.Repo.one()
    end

    reader = Task.async(fn -> unboxed(fn -> Arca.Repo.read_transaction(plain) end) end)
    assert {:ok, nil} = Task.await(reader, 5_000)

    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer, 25_000)
  end

  @tag :postgres
  test "shared readers hold a row together, and a writer waits for every one of them", %{
    claim: claim
  } do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      # One writer at a time and snapshot reads: there is no shared row
      # lock to hold.
      :ok
    else
      test = self()

      holder = fn label ->
        Task.async(fn ->
          unboxed(fn ->
            Arca.Repo.read_transaction(fn ->
              detail = shared_detail(claim)
              send(test, {:sharing, label})

              receive do
                :release -> detail
              end
            end)
          end)
        end)
      end

      first = holder.(:first)
      assert_receive {:sharing, :first}, 5_000
      second = holder.(:second)
      assert_receive {:sharing, :second}, 5_000

      writer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.Repo.locking_transaction(fn -> locked_detail(claim) end)
          end)
        end)

      refute Task.yield(writer, 300), "the writer locked a row two readers shared"
      send(first.pid, :release)
      assert {:ok, nil} = Task.await(first, 5_000)
      refute Task.yield(writer, 300), "the writer locked a row a reader still shared"
      send(second.pid, :release)
      assert {:ok, nil} = Task.await(second, 5_000)
      assert {:ok, nil} = Task.await(writer, 25_000)
    end
  end
end
