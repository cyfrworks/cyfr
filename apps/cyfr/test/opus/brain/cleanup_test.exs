# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain.CleanupTest do
  @moduledoc """
  The `brain_cleanup` consumer (`Opus.Brain.Cleanup`) against the scripted
  backends service, the test playing the row's driver: a removal the
  driver confirms is receipted `applied`; one the driver refuses, one
  whose answer is lost and one while the box is away stay owed and are
  tried again at the next drain; a successor's session and a row gone are
  `superseded`, a row that runs no driver `refused`, and none of the three
  opens anything. Every receipt is read whole from the store.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Brain.Cleanup

  @root :crypto.strong_rand_bytes(32)
  @session "1b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "cleanup-person", provider: "local", verified: true})

    athanor = Sanctum.Test.People.athanor!(user)

    ctx = %{
      Sanctum.TestContext.local(:prism)
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    actor = Sanctum.Context.actor(ctx)
    {:ok, thread} = Arca.Test.Days.thread(actor)
    row = brain_row!(actor, "claude-code")
    {:ok, fake: fake, actor: actor, thread: thread, row: row}
  end

  defp brain_row!(
         actor,
         name,
         command \\ "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323"
       ) do
    {:ok, row} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json: Jason.encode!(%{"command" => command, "env" => %{}})
      })

    row
  end

  defp owed!(actor, thread_id, row) do
    record =
      Prima.OutboxRecord.brain_forget(%{
        athanor_id: actor.athanor_id,
        thread_id: thread_id,
        agent: "aqua",
        row_id: row.id,
        session: @session,
        generation: 0
      })

    {:ok, :ok} = Arca.Repo.transaction(fn -> Arca.Outbox.put!(actor, record) end)
    record
  end

  defp pending(actor) do
    {:ok, records} = Arca.Outbox.pending(actor, Cleanup.consumer(), "brain_forget")
    records
  end

  defp outcome(actor, record),
    do:
      Arca.ConsumerReceipts.outcome(actor, Cleanup.consumer(), Prima.OutboxRecord.source(record))

  # A drain, run beside the test, which plays the row's driver.
  defp draining(actor), do: Task.async(fn -> Cleanup.drain(actor.athanor_id) end)

  # The driver's process opened, its hello written, its one command read.
  defp driver!(fake, row) do
    assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 5_000
    assert home == row.id
    assert_receive {:session, "recv", %{"after" => 0}, _fields}, 5_000

    Scripted.write(
      fake,
      row.id,
      Jason.encode!(%{"t" => "hello", "v" => 1, "driver" => "cyfr-claude-code", "boot" => "b1"})
    )

    assert_receive {:session, "send", %{"lines" => [line]}, _fields}, 5_000
    Jason.decode!(line)
  end

  defp say(fake, row, event), do: Scripted.write(fake, row.id, Jason.encode!(event))

  test "a confirmed removal is receipted applied; a refused one stays owed and is tried again",
       %{fake: fake, actor: actor, thread: thread, row: row} do
    record = owed!(actor, thread.id, row)

    task = draining(actor)
    %{"t" => "forget", "id" => id, "session" => @session} = driver!(fake, row)
    say(fake, row, %{"t" => "refused", "id" => id, "reason" => "The folder could not be read."})
    assert Task.await(task, 10_000) == {:ok, %{"owed" => 1}}
    assert pending(actor) == [record]
    assert outcome(actor, record) == :none

    task = draining(actor)
    %{"t" => "forget", "id" => ^id} = driver!(fake, row)
    say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
    assert Task.await(task, 10_000) == {:ok, %{"applied" => 1}}
    assert pending(actor) == []
    assert outcome(actor, record) == {:ok, "applied"}

    # Nothing is owed any more: a drain opens nothing.
    assert Cleanup.drain(actor.athanor_id) == {:ok, %{}}
    refute_received {:session, "open", _open, _fields}
  end

  test "a lost answer and a box away leave the removal owed until the box answers",
       %{fake: fake, actor: actor, thread: thread, row: row} do
    record = owed!(actor, thread.id, row)

    task = draining(actor)
    _forget = driver!(fake, row)
    Scripted.end_sessions(fake, row.id)
    assert Task.await(task, 10_000) == {:ok, %{"owed" => 1}}

    Scripted.down(fake)
    assert Cleanup.drain(actor.athanor_id) == {:ok, %{"owed" => 1}}
    assert pending(actor) == [record]
    Scripted.up(fake)

    task = draining(actor)
    %{"id" => id} = driver!(fake, row)
    say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
    assert Task.await(task, 30_000) == {:ok, %{"applied" => 1}}
    assert outcome(actor, record) == {:ok, "applied"}
  end

  test "a successor's session and a row gone are superseded, a row with no driver refused, none opened",
       %{actor: actor, thread: thread, row: row} do
    successor = owed!(actor, thread.id, row)

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
        set: [brain_session: @session, brain_generation: 1]
      )

    gone = brain_row!(actor, "claude-code-gone")
    vanished = owed!(actor, "thr_gone", gone)
    {1, _} = Arca.Repo.delete_all(from(r in Arca.Schemas.McpServer, where: r.id == ^gone.id))

    bare = brain_row!(actor, "claude-code-bare", "npx -y @anthropic-ai/claude-code@2.1.323")
    catalyst_era = owed!(actor, "thr_bare", bare)

    assert Cleanup.drain(actor.athanor_id) == {:ok, %{"superseded" => 2, "refused" => 1}}
    assert outcome(actor, successor) == {:ok, "superseded"}
    assert outcome(actor, vanished) == {:ok, "superseded"}
    assert outcome(actor, catalyst_era) == {:ok, "refused"}
    assert pending(actor) == []
    refute_received {:session, "open", _open, _fields}

    # The successor's session is untouched.
    assert {:ok, %{brain_session: @session, brain_generation: 1}} =
             Arca.ThreadStorage.get(actor, thread.id)
  end

  test "another member's claim on the athanor holds the drain off", %{
    actor: actor,
    thread: thread,
    row: row
  } do
    record = owed!(actor, thread.id, row)

    {:ok, _claim} =
      Arca.JobClaims.claim(Cleanup.consumer(), actor.athanor_id, "boot_other", 60_000)

    assert Cleanup.drain(actor.athanor_id) == :busy
    assert pending(actor) == [record]
    refute_received {:session, "open", _open, _fields}
  end
end
