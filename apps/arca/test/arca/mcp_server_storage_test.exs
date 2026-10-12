# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorageTest do
  # Takes a member slot through `Arca.ControlPlane`, which writes the
  # process-wide standing; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.McpServerStorage
  alias Arca.Schemas.CellLease

  @standing [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    saved = Map.new(@standing, &{&1, :persistent_term.get(&1, :absent)})

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    # The epoch's raise is published under this member's slot.
    node = "node-mcp-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    {:ok, actor: Arca.Test.Actor.local(), slot: slot}
  end

  describe "insert/2" do
    test "creates a new server config", %{actor: actor} do
      attrs = %{cap: 0, name: "notion", url: "https://mcp.notion.com/mcp"}

      assert {:ok, server} = McpServerStorage.insert(actor, attrs)
      assert server.name == "notion"
      assert server.url == "https://mcp.notion.com/mcp"
      assert server.enabled == true
    end

    test "records the actor's user as the row's creator, whatever the attrs say",
         %{actor: actor} do
      attrs = %{cap: 0, name: "created", url: "https://a.com/mcp", created_by: "usr_someone_else"}

      assert {:ok, %{created_by: creator}} = McpServerStorage.insert(actor, attrs)

      assert creator == actor.user_id

      {:ok, updated} = McpServerStorage.update(actor, "created", %{enabled: false})

      assert updated.created_by == actor.user_id
    end

    test "stores config_json verbatim (caller serializes)", %{actor: actor} do
      json = ~s({"headers":{"Authorization":"vault:GH_TOKEN"},"timeout_ms":15000})

      attrs = %{
        cap: 0,
        name: "github",
        url: "https://mcp.github.com/mcp",
        config_json: json
      }

      assert {:ok, _} = McpServerStorage.insert(actor, attrs)
      assert {:ok, server} = McpServerStorage.get(actor, "github")
      assert server.config_json == json
    end

    test "a name the athanor already uses is refused, and the stored row is kept",
         %{actor: actor} do
      attrs = %{cap: 0, name: "test-server", url: "https://old.example.com/mcp"}
      assert {:ok, %{id: id}} = McpServerStorage.insert(actor, attrs)

      attrs2 = %{cap: 0, name: "test-server", url: "https://new.example.com/mcp"}
      assert {:error, :exists} = McpServerStorage.insert(actor, attrs2)

      assert {:ok, [%{id: ^id, url: "https://old.example.com/mcp"}]} =
               McpServerStorage.list(actor)
    end

    test "a missing or malformed cap is refused as a validation error, and nothing is written",
         %{actor: actor} do
      attrs = %{name: "uncapped", url: "https://x.com/mcp"}

      for cap <- [:missing, nil, -1, "5", 1.5] do
        attrs = if cap == :missing, do: attrs, else: Map.put(attrs, :cap, cap)

        assert {:error, {:validation, %{cap: ["must be a non-negative integer"]}}} =
                 McpServerStorage.insert(actor, attrs)
      end

      assert {:ok, []} = McpServerStorage.list(actor)
    end

    test "the athanor's servers stop at the caller's cap, counting no other athanor's",
         %{actor: actor} do
      other = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      for name <- ~w(o1 o2 o3) do
        assert {:ok, _} =
                 McpServerStorage.insert(other, %{cap: 0, name: name, url: "https://o.com/mcp"})
      end

      for name <- ~w(s1 s2) do
        assert {:ok, row} =
                 McpServerStorage.insert(actor, %{cap: 2, name: name, url: "https://a.com/mcp"})

        refute Map.has_key?(row, :cap)
      end

      assert {:error, :server_cap} =
               McpServerStorage.insert(actor, %{cap: 2, name: "s3", url: "https://a.com/mcp"})

      assert {:ok, [%{name: "s1"}, %{name: "s2"}]} = McpServerStorage.list(actor)

      # A deleted server frees its place: every row the athanor holds counts.
      assert {:ok, _} = McpServerStorage.delete(actor, "s1")

      assert {:ok, _} =
               McpServerStorage.insert(actor, %{cap: 2, name: "s3", url: "https://a.com/mcp"})

      assert {:error, :server_cap} =
               McpServerStorage.insert(actor, %{cap: 2, name: "s4", url: "https://a.com/mcp"})

      # 0 is no ceiling: it admits where 2 refused.
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{cap: 0, name: "s4", url: "https://a.com/mcp"})

      assert {:ok, servers} = McpServerStorage.list(actor)
      assert Enum.map(servers, & &1.name) == ~w(s2 s3 s4)
    end

    test "an athanor with no row is refused :not_found, and nothing is written" do
      rowless =
        Arca.Test.Actor.local(athanor_id: "ath_mcp_rowless_#{System.unique_integer([:positive])}")

      assert {:error, :not_found} =
               McpServerStorage.insert(rowless, %{
                 cap: 0,
                 name: "orphan",
                 url: "https://x.com/mcp"
               })

      assert {:ok, []} = McpServerStorage.list(rowless)
    end
  end

  describe "get/2" do
    test "returns server by name", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "myserver",
                 url: "https://a.com/mcp"
               })

      assert {:ok, server} = McpServerStorage.get(actor, "myserver")
      assert server.name == "myserver"
    end

    test "returns not_found for missing server", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.get(actor, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all servers for tenant", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "s1",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "s2",
                 url: "https://b.com/mcp"
               })

      assert {:ok, servers} = McpServerStorage.list(actor)
      assert length(servers) == 2
      names = Enum.map(servers, & &1.name)
      assert "s1" in names
      assert "s2" in names
    end

    test "returns empty list when no servers", %{actor: actor} do
      assert {:ok, []} = McpServerStorage.list(actor)
    end
  end

  describe "delete/2" do
    test "removes a server and answers the row it removed", %{actor: actor} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "deleteme",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{id: ^id, name: "deleteme"}} = McpServerStorage.delete(actor, "deleteme")

      assert {:error, :not_found} = McpServerStorage.get(actor, "deleteme")
    end

    test "a server that does not exist is not found", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.delete(actor, "nonexistent")
    end
  end

  describe "update/4" do
    test "updates specific fields", %{actor: actor} do
      assert {:ok, _} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "updatable",
                 url: "https://old.com/mcp"
               })

      assert {:ok, server} = McpServerStorage.update(actor, "updatable", %{enabled: false})

      assert server.enabled == false
      assert server.url == "https://old.com/mcp"
    end

    test "returns not_found for missing server", %{actor: actor} do
      assert {:error, :not_found} = McpServerStorage.update(actor, "nope", %{enabled: false})
    end
  end

  describe "epochs" do
    test "a row is inserted at epoch 1 and every write raises it in the same statement",
         %{actor: actor} do
      assert {:ok, %{id: id, epoch: 1, revision: 0}} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "epochal",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{epoch: 2, revision: 1}} =
               McpServerStorage.update(actor, "epochal", %{enabled: false})

      assert {:ok, %{epoch: 3, revision: 2}} = McpServerStorage.bump_epoch(actor, id)
      assert {:ok, %{epoch: 3, revision: 2}} = McpServerStorage.get_by_id(actor, id)
      assert {:ok, %{epoch: 4, revision: 3}} = McpServerStorage.bump_epoch(actor, id, 3)
    end

    test "a raise under a slot taken over after the member read it publishes nothing",
         %{actor: actor, slot: slot} do
      {:ok, %{id: id}} =
        McpServerStorage.insert(actor, %{cap: 0, name: "held", url: "https://x.com/mcp"})

      # The member still believes it holds the slot; the row says otherwise.
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1, fence: 9]
        )

      assert ControlPlane.held?()
      assert {:error, :not_owner} = McpServerStorage.bump_epoch(actor, id)
      assert {:error, :not_owner} = McpServerStorage.bump_epoch(actor, id, 1)
      assert {:ok, %{epoch: 1, revision: 0}} = McpServerStorage.get_by_id(actor, id)
    end

    test "a raise under a slot that ran out with no successor publishes nothing",
         %{actor: actor, slot: slot} do
      {:ok, %{id: id}} =
        McpServerStorage.insert(actor, %{cap: 0, name: "lapsed", url: "https://x.com/mcp"})

      past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [lease_until: past]
        )

      assert {:error, :not_owner} = McpServerStorage.bump_epoch(actor, id)
      assert {:ok, %{epoch: 1}} = McpServerStorage.get_by_id(actor, id)
    end

    test "a member that holds no slot where a claimant runs raises nothing", %{actor: actor} do
      {:ok, %{id: id}} =
        McpServerStorage.insert(actor, %{cap: 0, name: "slotless", url: "https://x.com/mcp"})

      previous = Application.get_env(:arca, :control_plane_claim_enabled)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:arca, :control_plane_claim_enabled),
          else: Application.put_env(:arca, :control_plane_claim_enabled, previous)
      end)

      Application.put_env(:arca, :control_plane_claim_enabled, true)
      ControlPlane.forget()
      ControlPlane.forget_generation()
      ControlPlane.record(:unclaimed)

      assert {:error, :not_owner} = McpServerStorage.bump_epoch(actor, id)
      assert {:ok, %{epoch: 1}} = McpServerStorage.get_by_id(actor, id)
    end

    test "another athanor's row is not found, and is not raised", %{actor: actor} do
      theirs = Arca.Test.Actor.local(athanor_id: "ath_mcp_theirs", user_id: "user_theirs")
      Arca.Test.Actor.ensure_athanor_row(theirs.athanor_id)

      {:ok, %{id: id}} =
        McpServerStorage.insert(theirs, %{cap: 0, name: "theirs", url: "https://x.com/mcp"})

      assert {:error, :not_found} = McpServerStorage.bump_epoch(actor, id)
      assert {:ok, %{epoch: 1}} = McpServerStorage.get_by_id(theirs, id)
    end

    test "a write naming the epoch it read is refused once the row has moved on",
         %{actor: actor} do
      assert {:ok, %{id: id}} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "casrow",
                 url: "https://x.com/mcp"
               })

      assert {:ok, %{epoch: 2}} =
               McpServerStorage.update(actor, "casrow", %{url: "https://y.com/mcp"}, 1)

      assert {:error, :stale_epoch} =
               McpServerStorage.update(actor, "casrow", %{url: "https://z.com/mcp"}, 1)

      assert {:error, :stale_epoch} = McpServerStorage.bump_epoch(actor, id, 1)

      assert {:ok, %{url: "https://y.com/mcp", epoch: 2}} = McpServerStorage.get(actor, "casrow")

      assert {:error, :not_found} = McpServerStorage.update(actor, "absent", %{enabled: true}, 1)
    end

    test "an http row has a url and a stdio row has none", %{actor: actor} do
      stdio = Jason.encode!(%{"backends" => []})

      assert {:ok, %{transport: "stdio", url: nil}} =
               McpServerStorage.insert(actor, %{
                 cap: 0,
                 name: "piped",
                 transport: "stdio",
                 url: nil,
                 config_json: stdio
               })

      for attrs <- [
            %{cap: 0, name: "bad-http", transport: "http", url: nil},
            %{cap: 0, name: "bad-stdio", transport: "stdio", url: "https://x.com/mcp"}
          ] do
        assert {:error, _} = McpServerStorage.insert(actor, attrs)
      end
    end

    test "the fence reads each named row with its athanor's status, in its own athanor only" do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      {:ok, a} =
        McpServerStorage.insert(actor_a, %{
          cap: 0,
          name: "fenced",
          url: "https://a.com/mcp"
        })

      {:ok, b} =
        McpServerStorage.insert(actor_b, %{
          cap: 0,
          name: "fenced",
          url: "https://b.com/mcp"
        })

      assert {:ok, rows} =
               McpServerStorage.fenced([
                 {actor_a.athanor_id, a.id},
                 {actor_a.athanor_id, b.id},
                 {actor_b.athanor_id, b.id}
               ])

      assert %{row: %{id: a_id}} = rows[{actor_a.athanor_id, a.id}]
      assert a_id == a.id
      assert %{row: %{id: b_id}} = rows[{actor_b.athanor_id, b.id}]
      assert b_id == b.id
      refute Map.has_key?(rows, {actor_a.athanor_id, b.id})
    end
  end

  describe "tenant isolation" do
    test "different tenants see different servers", %{actor: _actor} do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      assert {:ok, _} =
               McpServerStorage.insert(actor_a, %{
                 cap: 0,
                 name: "shared-name",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor_b, %{
                 cap: 0,
                 name: "shared-name",
                 url: "https://b.com/mcp"
               })

      assert {:ok, server_a} = McpServerStorage.get(actor_a, "shared-name")
      assert server_a.url == "https://a.com/mcp"

      assert {:ok, server_b} = McpServerStorage.get(actor_b, "shared-name")
      assert server_b.url == "https://b.com/mcp"
    end

    test "delete only affects own tenant", %{actor: _actor} do
      actor_a = Arca.Test.Actor.local(athanor_id: "ath_a", user_id: "user_a")
      actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")

      assert {:ok, _} =
               McpServerStorage.insert(actor_a, %{
                 cap: 0,
                 name: "isolated",
                 url: "https://a.com/mcp"
               })

      assert {:ok, _} =
               McpServerStorage.insert(actor_b, %{
                 cap: 0,
                 name: "isolated",
                 url: "https://b.com/mcp"
               })

      assert {:ok, _} = McpServerStorage.delete(actor_a, "isolated")
      assert {:error, :not_found} = McpServerStorage.get(actor_a, "isolated")
      assert {:ok, _} = McpServerStorage.get(actor_b, "isolated")
    end
  end

  describe "config/1" do
    test "decodes a stored row's config_json" do
      assert McpServerStorage.config(%{config_json: ~s({"headers":{"X":"1"},"timeout_ms":5})}) ==
               %{"headers" => %{"X" => "1"}, "timeout_ms" => 5}
    end

    test "reads as empty rather than raising, for every shape a row can hold" do
      # The consent digest, the header resolver and the vault reconciler all
      # decode here; if they disagreed about a malformed row the digest would
      # describe a server that is not the one being called.
      for server <- [
            %{config_json: nil},
            %{config_json: ""},
            %{config_json: "not json"},
            # valid JSON, but not an object
            %{config_json: "[1,2,3]"},
            %{config_json: "42"},
            %{},
            nil
          ] do
        assert McpServerStorage.config(server) == %{}, "expected #{inspect(server)} to read empty"
      end
    end

    test "round-trips what put/2 stored", %{actor: actor} do
      config = %{"headers" => %{"Authorization" => "vault:NOTION"}, "tool_patterns" => ["a_*"]}

      {:ok, _} =
        McpServerStorage.insert(actor, %{
          cap: 0,
          name: "roundtrip",
          url: "https://example.test",
          config_json: Jason.encode!(config)
        })

      {:ok, row} = McpServerStorage.get(actor, "roundtrip")
      assert McpServerStorage.config(row) == config
    end
  end
end

defmodule Arca.McpServerStorageRaceTest do
  @moduledoc """
  Two raises of one server's epoch at once — a reconcile of a vault
  rotation and another write to the row — on connections of their own
  outside the sandbox: the one that read the older revision waits on the
  row, then is refused `:stale`, and the row holds the winner's raise
  alone.

  PostgreSQL only: SQLite's one write lock serializes the two whole, so
  there is no wait inside one to observe.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.McpServerStorage
  alias Arca.Schemas.{Athanor, CellLease, McpServer}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  @standing [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    athanor = "ath_mcp_race_#{System.unique_integer([:positive])}"
    node = "node-mcp-race-#{System.unique_integer([:positive])}"
    saved = Map.new(@standing, &{&1, :persistent_term.get(&1, :absent)})
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      unboxed(fn ->
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
        Arca.Repo.delete_all(from(s in McpServer, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor))
      end)
    end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor, user_id: "user_race"), node: node}
  end

  test "a raise that read the older revision waits, then is refused, and the winner's raise stands",
       %{actor: actor, node: node} do
    if Arca.Repo.adapter() != Ecto.Adapters.SQLite3 do
      {:ok, _slot} = unboxed(fn -> Arca.ControlPlane.take(node, node <> "#boot_a", 60_000) end)

      {:ok, %{id: id}} =
        unboxed(fn ->
          McpServerStorage.insert(actor, %{cap: 0, name: "raced", url: "https://x.com/mcp"})
        end)

      test = self()

      # The winner raises inside a transaction held open, so the row stays
      # locked at its new revision until it commits.
      winner =
        Task.async(fn ->
          unboxed(fn ->
            Arca.Repo.transaction(fn ->
              raised = McpServerStorage.bump_epoch(actor, id)
              send(test, {:holding, raised})

              receive do
                :commit -> raised
              end
            end)
          end)
        end)

      assert_receive {:holding, {:ok, %{epoch: 2, revision: 1}}}, 5_000

      # The loser reads the committed row — revision 0 — and waits on the
      # winner's lock at its publishing statement.
      loser = Task.async(fn -> unboxed(fn -> McpServerStorage.bump_epoch(actor, id) end) end)
      refute Task.yield(loser, 300), "the loser published past the winner's lock"

      send(winner.pid, :commit)
      assert {:ok, {:ok, %{epoch: 2}}} = Task.await(winner, 25_000)
      assert {:error, :stale} = Task.await(loser, 25_000)

      assert {:ok, %{epoch: 2, revision: 1}} =
               unboxed(fn -> McpServerStorage.get_by_id(actor, id) end)
    end
  end
end

defmodule Arca.McpServerStorageCapRaceTest do
  @moduledoc """
  Creates racing for an athanor's last server places, each on a connection
  of its own outside the sandbox: `insert/2` locks the athanor's row,
  counts and inserts in one transaction, so exactly `cap` of them land and
  the rest are refused `:server_cap`.

  On PostgreSQL another transaction holds the athanor's row until every
  creator is seen waiting on a lock, so all of them contend at once; on
  SQLite the locking transaction's one write lock serializes them. The
  case works in an athanor of its own, whose rows it deletes when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.McpServerStorage
  alias Arca.Schemas.{Athanor, McpServer}
  alias Ecto.Adapters.SQL.Sandbox

  @cap 3
  @creates 8

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    athanor = "ath_mcp_cap_race_#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(s in McpServer, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor))
      end)
    end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor, user_id: "user_cap_race")}
  end

  test "concurrent creates stop at the cap", %{actor: actor} do
    test = self()

    create = fn name ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})

          McpServerStorage.insert(actor, %{cap: @cap, name: name, url: "https://x.com/mcp"})
        end)
      end)
    end

    answers =
      if postgres?() do
        holder =
          holding(fn ->
            from(a in Athanor, where: a.id == ^actor.athanor_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()
          end)

        creators = for i <- 1..@creates, do: create.("race-#{i}")

        for _ <- creators do
          assert_receive {:backend, backend}, 15_000
          await_lock_wait(backend)
        end

        release(holder)
        Enum.map(creators, &Task.await(&1, 30_000))
      else
        for(i <- 1..@creates, do: create.("race-#{i}")) |> Enum.map(&Task.await(&1, 30_000))
      end

    assert Enum.count(answers, &match?({:ok, _}, &1)) == @cap
    assert Enum.count(answers, &(&1 == {:error, :server_cap})) == @creates - @cap
    assert {:ok, rows} = unboxed(fn -> McpServerStorage.list(actor) end)
    assert length(rows) == @cap
  end

  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            result = lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> result
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    assert {:ok, _} = Task.await(task, 30_000)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Holds until `pid`'s backend waits on a lock: an observed state, bounded
  # by `tries`, never a timing.
  defp await_lock_wait(pid, tries \\ 500)

  defp await_lock_wait(_pid, 0), do: flunk("a create never waited on the athanor's lock")

  defp await_lock_wait(pid, tries) do
    %{rows: rows} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(20)
      await_lock_wait(pid, tries - 1)
    end
  end
end
