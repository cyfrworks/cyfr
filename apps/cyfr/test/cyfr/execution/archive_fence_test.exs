# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.ArchiveFenceTest.GatedAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A put waits for its release while a test process is registered under
  # the gate's name.
  def put(actor, path, content) do
    case Process.whereis(:archive_fence_put_gate) do
      nil ->
        :ok

      gate ->
        send(gate, {:gated, self()})

        receive do
          :release -> :ok
        end
    end

    Arca.Adapters.Local.put(actor, path, content)
  end
end

defmodule Cyfr.Execution.ArchiveFenceTest do
  @moduledoc """
  Archiving an estate retires the grant of every execution admitted in it,
  whether or not anyone hears of the archive (`Sanctum.ExecutionStanding`).

  With the archive watch absent, an attached guest's renewal, storage
  write and read, credential projection, token release, rate checkpoint,
  child admission, deltas and completion are each refused `lost` through
  the real signed host handler, and none leaves an effect: no bytes, no
  child, no success. A reopen admits only fresh roots: the old grant still
  refuses. A write in flight when the archive lands is `uncertain`, never
  confirmed and never replayed; a completion that lands after the archive
  is recorded as neither a success nor output. An in-chain call is
  admitted only under the trusted lineage of an attempt whose grant
  stands. The sweep finds every retired attempt — a page and more,
  paused turns and children among them — and retires each once, never
  from a member that lost its slot.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Execution.{Dispatch, Record, Sweeper}
  alias Cyfr.Test.AttemptFixtures
  alias Sanctum.Tenancy.Athanors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    test_dir =
      Path.join(System.tmp_dir!(), "archive_fence_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    previous = Map.new([:base_path, :storage_adapter], &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    # The archive watch is the accelerator; these cases are the archive
    # nobody heard.
    refute Process.whereis(Cyfr.Execution.ArchiveWatch)

    estate = estate!()
    {:ok, estate: estate, ctx: ctx(estate.id)}
  end

  defp estate! do
    {:ok, estate} =
      Athanors.create(%{
        kind: "group",
        name: "Fence",
        slug: "fence-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    estate
  end

  defp ctx(athanor_id),
    do:
      Sanctum.internal_context(
        user_id: "usr_fence",
        athanor_id: athanor_id,
        scope: :athanor,
        permissions: [:*]
      )

  defp archive!(estate) do
    {:ok, archived} = Athanors.archive(estate, force: true)
    assert archived.status == "archived"
    archived
  end

  # A storage-authorized guest, attached through the signed host handler.
  defp attached(ctx, opts \\ []) do
    edge = %Edge{storage: %{paths: ["data/"], actions: ["read", "write", "list", "exists"]}}

    AttemptFixtures.attached!(
      [ctx: ctx, authority: %{Authority.zero() | resources: edge}] ++ opts
    )
  end

  defp write(path, text),
    do: %{"action" => "write", "path" => path, "content" => Base.encode64(text)}

  defp storage(fixture, args), do: AttemptFixtures.call(fixture, "storage", args)

  defp renew(fixture),
    do: AttemptFixtures.call(fixture, "renew", %{"attempts" => [fixture.attempt]})

  defp complete(fixture, output) do
    AttemptFixtures.call(fixture, "complete", %{
      "outcome" => AttemptFixtures.outcome(fixture, "completed", %{"output" => output})
    })
  end

  defp stored?(fixture, segments),
    do: Arca.Adapters.Local.exists?(Sanctum.Context.actor(fixture.ctx), segments)

  defp row(fixture), do: Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id)

  defp attempt_row(fixture), do: Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, fixture.attempt)

  defp intents(fixture),
    do:
      Arca.ExecutionAttempts.write_intents(
        Cyfr.Actor.in_athanor(fixture.athanor_id),
        fixture.attempt
      )

  describe "an attached guest after an archive nobody heard" do
    test "renew, a storage write and completion each refuse, and nothing is written or completed",
         %{estate: estate, ctx: ctx} do
      fixture = attached(ctx)
      assert %{"ok" => %{"written" => true}} = storage(fixture, write("data/before.txt", "kept"))

      archive!(estate)

      assert %{"ok" => %{} = renewals} = renew(fixture)
      assert renewals[fixture.attempt] == "lost"

      assert %{"error" => "lost"} = storage(fixture, write("data/after.txt", "late"))
      refute stored?(fixture, ["data", "after.txt"])

      assert %{"error" => "lost"} = complete(fixture, %{"answer" => 42})

      assert {:error, _lost} = Dispatch.await(fixture.pid, fixture.close)
      assert row(fixture).status == "failed"
      assert attempt_row(fixture).outcome != "ok"
      assert attempt_row(fixture).state == "failed"

      # What committed before the archive stays; nothing after it landed.
      assert stored?(fixture, ["data", "before.txt"])
      assert [%{path: "data/before.txt", state: "confirmed"}] = intents(fixture)
    end

    test "every other discrete effect refuses lost and leaves nothing", %{
      estate: estate,
      ctx: ctx
    } do
      read = attached(ctx)
      assert %{"ok" => %{"written" => true}} = storage(read, write("data/r.txt", "x"))

      fixtures = %{
        read: read,
        attach: attached(ctx),
        oauth_token: attached(ctx),
        take_rate: attached(ctx),
        push_deltas: attached(ctx),
        fetch_artifact: attached(ctx),
        admit_child: attached(ctx, component_type: :formula)
      }

      archive!(estate)

      calls = %{
        read: fn f -> storage(f, %{"action" => "read", "path" => "data/r.txt"}) end,
        attach: fn f -> AttemptFixtures.call(f, "attach", %{"assignment" => f.assignment}) end,
        oauth_token: fn f -> AttemptFixtures.call(f, "oauth_token", %{"provider" => "github"}) end,
        take_rate: fn f ->
          AttemptFixtures.call(f, "take_rate", %{"bucket" => "http:" <> f.component_ref})
        end,
        push_deltas: fn f ->
          AttemptFixtures.call(f, "push_deltas", %{
            "deltas" => [
              AttemptFixtures.delta(f, Jason.encode!(%{"type" => "text.delta", "text" => "hi"}))
            ]
          })
        end,
        fetch_artifact: fn f ->
          AttemptFixtures.call(f, "fetch_artifact", %{
            "digest" => Cyfr.Digest.sha256(f.component_ref)
          })
        end,
        admit_child: fn f ->
          AttemptFixtures.call(f, "admit_child", %{
            "reference" => "reagent:local.fence-child:0.1.0",
            "input" => %{},
            "guest_fn" => "spawn",
            "child_key" => "ck_#{System.unique_integer([:positive])}"
          })
        end
      }

      for {effect, fixture} <- fixtures do
        assert %{"error" => "lost"} = calls[effect].(fixture), "#{effect} was admitted"
      end

      # No child was admitted under the retired formula.
      refute Arca.Repo.exists?(
               from(e in Arca.Schemas.Execution,
                 where: e.parent_execution_id == ^fixtures.admit_child.execution_id
               )
             )
    end

    test "a failure still retires the run, and the text it held is not published", %{
      estate: estate,
      ctx: ctx
    } do
      # A person's own context: the vault is theirs to write.
      person =
        Sanctum.Context.build(
          user_id: "usr_fence",
          athanor_id: ctx.athanor_id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      fixture =
        AttemptFixtures.attached!(
          ctx: person,
          vault: %{kind: "api_key", fields: %{"KEY" => "sk-fence-secret-value"}}
        )

      :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, fixture.ctx)

      # The tail that could begin the secret's masked form stays in the
      # emitter until the stream ends.
      assert %{"ok" => [_reply]} =
               AttemptFixtures.call(fixture, "push_deltas", %{
                 "deltas" => [
                   AttemptFixtures.delta(
                     fixture,
                     Jason.encode!(%{"type" => "text.delta", "text" => "hello sk-fen"})
                   )
                 ]
               })

      assert Enum.any?(events(), &match?(%{type: "emit", data: %{"text" => "hello "}}, &1))
      archive!(estate)

      assert %{"ok" => _failure} =
               AttemptFixtures.call(fixture, "fail", %{
                 "outcome" => AttemptFixtures.outcome(fixture, "failed", %{"error" => "stop"})
               })

      assert {:error, _} = Dispatch.await(fixture.pid, fixture.close)
      assert row(fixture).status == "failed"
      assert Enum.filter(events(), &match?(%{type: "emit"}, &1)) == []
    end
  end

  describe "a reopen" do
    test "admits only fresh roots: the old grant still refuses", %{estate: estate, ctx: ctx} do
      old = attached(ctx)

      estate |> archive!() |> Athanors.unarchive()

      assert %{"ok" => %{} = renewals} = renew(old)
      assert renewals[old.attempt] == "lost"
      assert %{"error" => "lost"} = storage(old, write("data/old.txt", "late"))
      refute stored?(old, ["data", "old.txt"])

      fresh = attached(ctx)
      assert fresh.grant.generation > old.grant.generation
      assert %{"ok" => %{} = fresh_renewals} = renew(fresh)
      assert %{"lease_until" => _} = fresh_renewals[fresh.attempt]
      assert %{"ok" => %{"written" => true}} = storage(fresh, write("data/new.txt", "fresh"))

      # A child never refreshes its parent's standing: one admitted under
      # the old root's row now is refused.
      assert {:error, :not_standing} =
               Record.write_started(
                 Record.new(ctx, "reagent:local.fence-child:0.1.0", %{},
                   parent_execution_id: old.execution_id,
                   root_execution_id: old.execution_id
                 )
               )
    end

    test "missing generation refuses; no default repairs it", %{ctx: ctx} do
      attrs = %{
        id: Cyfr.UUID7.execution_id(),
        reference: "reagent:local.fence:0.1.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "reagent"
      }

      assert {:error, :missing_grant} = Arca.Execution.admit(attrs, [])

      assert {:error, :missing_grant} =
               Arca.Execution.admit(attrs, verify: &Sanctum.ExecutionStanding.verify/1)

      refute Arca.Repo.get(Arca.Schemas.Execution, attrs.id)
    end
  end

  describe "an effect in flight when the archive lands" do
    test "a storage write is uncertain, never confirmed, and never replayed", %{
      estate: estate,
      ctx: ctx
    } do
      fixture = attached(ctx)
      Application.put_env(:arca, :storage_adapter, __MODULE__.GatedAdapter)
      Process.register(self(), :archive_fence_put_gate)

      writer = Task.async(fn -> storage(fixture, write("data/in-flight.txt", "landed")) end)
      assert_receive {:gated, putter}, 5_000
      assert [%{state: "pending"}] = intents(fixture)

      archive!(estate)
      send(putter, :release)
      Process.unregister(:archive_fence_put_gate)

      assert %{"error" => "guest_error", "type" => "storage_uncertain"} = Task.await(writer)
      assert [%{state: "uncertain", reason: "hold_lost"}] = intents(fixture)

      # Nothing retries it: the next write under the retired grant is lost.
      assert %{"error" => "lost"} = storage(fixture, write("data/in-flight.txt", "again"))
      assert [%{state: "uncertain"}] = intents(fixture)
    end

    test "a completion recorded after the archive is neither a success nor output", %{
      estate: estate,
      ctx: ctx
    } do
      fixture = attached(ctx)
      archive!(estate)

      completed = Record.complete(fixture.record, %{"answer" => 42})
      assert {:error, :not_standing} = Record.write_completed(completed)

      assert %{status: "failed", output: nil} = row(fixture)
      assert %{state: "failed", outcome: "uncertain"} = attempt_row(fixture)

      assert {:error, :not_found} =
               Arca.ExecutionPayloads.get(
                 Sanctum.Context.actor(fixture.ctx),
                 fixture.execution_id,
                 "result"
               )
    end
  end

  describe "the in-chain gate" do
    setup %{ctx: ctx} do
      {:ok, authority: status_authority(), guest: Sanctum.Context.enter_guest(ctx)}
    end

    test "admits a call under an attempt whose grant stands", %{
      ctx: ctx,
      guest: guest,
      authority: authority
    } do
      assert {:ok, _status} = status(guest, authority, AttemptFixtures.lineage!(ctx))
    end

    test "refuses absent, partial or mismatched lineage, and a guest cannot supply it", %{
      ctx: ctx,
      guest: guest,
      authority: authority
    } do
      lineage = AttemptFixtures.lineage!(ctx)
      other = AttemptFixtures.lineage!(ctx)
      elsewhere = AttemptFixtures.lineage!(ctx(estate!().id))

      for bad <- [
            nil,
            %{attempt: lineage.attempt},
            %{parent_execution_id: lineage.parent_execution_id},
            %{lineage | attempt: other.attempt},
            %{lineage | parent_execution_id: other.parent_execution_id},
            %{lineage | attempt: "att_forged"},
            elsewhere
          ] do
        assert {:error, refusal} = status(guest, authority, bad), inspect(bad)
        assert refusal in [:archived, {:invalid_argument, refusal_sentence()}]
      end

      # The guest's own spelling is dropped before the gate reads anything.
      forged = %{
        "action" => "status",
        "parent_execution_id" => lineage.parent_execution_id,
        "attempt" => lineage.attempt
      }

      assert {:error, {:invalid_argument, _}} =
               Cyfr.Ops.Catalog.call_in_chain("system", guest, forged, authority)
    end

    test "refuses once the calling execution's estate was archived", %{
      estate: estate,
      ctx: ctx,
      guest: guest,
      authority: authority
    } do
      lineage = AttemptFixtures.lineage!(ctx)
      archive!(estate)
      assert {:error, :archived} = status(guest, authority, lineage)
    end
  end

  describe "the sweep" do
    test "retires every retired attempt past a page, paused turns and children among them, once",
         %{estate: estate, ctx: ctx} do
      page = Sweeper.bounds().retired_page
      grant = AttemptFixtures.grant(ctx.athanor_id)
      roots = for _ <- 1..(page + 2), do: root!(ctx, grant)
      {parent, parent_attempt} = hd(roots)
      child = child!(ctx, grant, parent, parent_attempt)
      turn = paused_turn!(ctx, grant)

      archive!(estate)

      # A member that no longer holds its slot retires nothing.
      key = {Arca.ControlPlane, :standing}
      standing = :persistent_term.get(key, :absent)
      Arca.ControlPlane.record(:lost)

      try do
        :ok = Sweeper.sweep()
      after
        if standing == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, standing)
      end

      assert open_count(ctx) == length(roots) + 2

      :ok = Sweeper.sweep()
      assert open_count(ctx) == 0

      for {id, _attempt} <- [child | roots] do
        assert %{status: status} = Arca.Repo.get!(Arca.Schemas.Execution, id)
        assert status in ["cancelled", "failed"], "#{id} ended #{status}"
      end

      assert {:ok, %{status: "cancelled"} = ended} = Arca.TurnStorage.get(actor(ctx), turn.id)

      assert %{status: "cancelled"} =
               Arca.Repo.get!(Arca.Schemas.Execution, ended.root_execution_id)

      assert %{released_at: %DateTime{}} =
               Arca.Repo.get_by!(Arca.Schemas.BudgetReservation,
                 root_execution_id: ended.root_execution_id
               )

      # No completion under a retired grant, and a second sweep finds
      # nothing to do again.
      refute Arca.Repo.exists?(
               from(a in Arca.Schemas.ExecutionAttempt,
                 where: a.athanor_id == ^ctx.athanor_id and a.outcome == "ok"
               )
             )

      :ok = Sweeper.sweep()
      assert open_count(ctx) == 0
      assert {:ok, []} = scan(ctx.athanor_id)
    end

    test "records its bounds without extending them" do
      assert %{interval_ms: 60_000, retired_page: 50} = Sweeper.bounds()
      assert Arca.ExecutionAttempts.lease_seconds() == 180
    end
  end

  # ---------------------------------------------------------------------------

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp root!(ctx, grant) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Cyfr.UUID7.execution_id(),
          reference: "reagent:local.fence-root:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {execution.id, attempt.attempt}
  end

  defp child!(ctx, grant, parent, parent_attempt) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Cyfr.UUID7.execution_id(),
          reference: "reagent:local.fence-child:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          parent_execution_id: parent,
          root_execution_id: parent
        },
        parent_attempt: parent_attempt,
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {execution.id, attempt.attempt}
  end

  # A turn paused for an approval: its root attempt and root row paused,
  # its reservation still held.
  defp paused_turn!(ctx, grant) do
    {:ok, thread} = Arca.ThreadStorage.create(actor(ctx))

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: root, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Cyfr.UUID7.execution_id(),
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, started} =
      Arca.TurnStorage.start(actor(ctx), turn.id, %{
        fence: turn.fence,
        root_execution_id: root.id,
        attempt: attempt.attempt,
        profile_id: "prof_fence",
        consent_id: "consent_fence"
      })

    {:ok, paused} = Arca.TurnStorage.pause(actor(ctx), turn.id, %{fence: started.fence})
    assert paused.status == "paused"
    paused
  end

  defp open_count(ctx) do
    Arca.Repo.aggregate(
      from(a in Arca.Schemas.ExecutionAttempt,
        where: a.athanor_id == ^ctx.athanor_id and a.state in ["running", "paused"]
      ),
      :count
    )
  end

  defp scan(athanor_id, cursor \\ nil, acc \\ []) do
    case Sanctum.ExecutionStanding.retired_attempts(Cyfr.Actor.system(), cursor, 50) do
      {:ok, []} -> {:ok, Enum.filter(acc, &(elem(&1, 2) == athanor_id))}
      {:ok, page} -> scan(athanor_id, page |> List.last() |> elem(1), acc ++ page)
    end
  end

  defp status(guest, authority, lineage) do
    opts = if lineage, do: [lineage: lineage], else: []
    Cyfr.Ops.Catalog.call_in_chain("system", guest, %{"action" => "status"}, authority, opts)
  end

  defp refusal_sentence, do: "An in-chain call names the execution that makes it"

  defp status_authority do
    node = "formula:local.fence-gate"

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => ["system.status"]}}
        }
      }
    }

    {:ok, blob} = Authority.Blob.parse(graph)

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-fence-gate",
          consent_id: "consent-fence-gate",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:fence-gate"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    authority
  end

  defp events do
    receive do
      {:execution_event, event} -> [event | events()]
    after
      300 -> []
    end
  end
end
