# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.AttemptMaskingTest do
  @moduledoc """
  A run's attempt is the one place its credentials are masked: the vault
  field unsealed for it at attach and every OAuth token it dispenses are
  masked in the events its guest emits, in the text its emitter still holds
  when the run closes — which goes out before the terminal row — and in the
  output, the result payload, a failure message, the lifecycle events and
  the answers the runner and the waiter get. A token asked for while the
  run closes is either masked or never dispensed. An attempt that ends
  before it closes its run, or whose opener exits, leaves nothing unmasked
  behind. Its status and its crash report show neither a credential nor the
  text its emitter holds back, nor what a call carried.

  Every call reaches the attempt as its runner's does: a signed host call
  (`Cyfr.Execution.Host`). The vault field begins with the token, so text
  that ends in the token is held back as the possible start of the field
  until the token is dispensed.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait
  import ExUnit.CaptureLog

  alias Cyfr.Execution.Dispatch
  alias Cyfr.Test.AttemptFixtures

  @token "ya29.token-0123456789"
  @field @token <> "-and-field"
  @redacted "[REDACTED]"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    fixture = attached!()
    :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, ctx)

    {:ok, ctx: ctx, fixture: fixture, id: fixture.execution_id}
  end

  test "a dispensed token and the vault field are masked in the events, output, row, payload and answers",
       %{ctx: ctx, fixture: fixture, id: id} do
    assert fixture.secrets == %{"KEY" => @field}
    assert %{"ok" => @token} = token(fixture)

    assert %{"sequence" => _} =
             emit!(fixture, %{"type" => "note", "text" => "#{@token} #{@field}"})

    assert %{"ok" => answered} = complete(fixture, %{"said" => "#{@token} / #{@field}"})
    assert answered == %{"said" => "#{@redacted} / #{@redacted}"}

    assert {:ok, result} = Dispatch.await(fixture.pid, fixture.close)
    assert result.output == %{"said" => "#{@redacted} / #{@redacted}"}
    refute_unmasked(result)

    assert [%{"text" => "#{@redacted} #{@redacted}"}] = emitted(live_events())

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "completed"
    refute_unmasked(row)

    assert {:ok, _row, payload} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

    assert payload =~ @redacted
    refute_unmasked(payload)
    refute_unmasked(Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id))
    refute_unmasked(event_rows(ctx, id))
  end

  test "held text goes out masked with the set as it stands at close, before the terminal row",
       %{ctx: ctx, fixture: fixture, id: id} do
    emit!(fixture, %{"type" => "text.delta", "text" => "the token is " <> @token})
    assert %{"ok" => @token} = token(fixture)

    assert %{"ok" => _output} = complete(fixture, %{"said" => "done"})
    assert {:ok, _result} = Dispatch.await(fixture.pid, fixture.close)

    live = live_events()
    assert Enum.map(emitted(live), & &1["text"]) == ["the token is ", @redacted]
    refute_unmasked(live)

    tail_at = Enum.find_index(live, &(&1.type == "emit" and &1.data["text"] == @redacted))
    completed_at = Enum.find_index(live, &(&1.type == "execution.completed"))
    assert is_integer(tail_at) and is_integer(completed_at) and tail_at < completed_at

    refute_unmasked(Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id))
  end

  test "the last delta of a stream that never ends reaches the stream before a failed row",
       %{fixture: fixture, id: id} do
    emit!(fixture, %{"type" => "text.delta", "text" => "partial ya29.tok"})

    assert %{"ok" => "upstream failed"} = fail(fixture, "upstream failed")
    assert {:error, "upstream failed"} = Dispatch.await(fixture.pid, fixture.close)

    live = live_events()
    assert Enum.map(emitted(live), & &1["text"]) == ["partial ", "ya29.tok"]
    assert [_, _, %{type: "execution.failed"}] = live
    assert %{status: "failed"} = Arca.Repo.get!(Arca.Schemas.Execution, id)
  end

  test "a failure message is masked in the row, its event and the answer",
       %{ctx: ctx, fixture: fixture, id: id} do
    assert %{"ok" => @token} = token(fixture)

    assert %{"ok" => answered} = fail(fixture, "upstream said #{@token} for #{@field}")
    assert {:error, message} = Dispatch.await(fixture.pid, fixture.close)
    assert message == "upstream said #{@redacted} for #{@redacted}"
    assert answered == message

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows)
    refute_unmasked(live_events())
  end

  test "a token asked for while the run closes is masked, and one asked for after it is never dispensed",
       %{fixture: fixture, id: id} do
    attempt = fixture.pid
    :sys.suspend(attempt)

    during = Task.async(fn -> token(fixture) end)
    wait_until(fn -> queued(attempt) == 1 end)
    closing = Task.async(fn -> complete(fixture, %{"said" => @token}) end)
    wait_until(fn -> queued(attempt) == 2 end)
    after_close = Task.async(fn -> token(fixture) end)
    wait_until(fn -> queued(attempt) == 3 end)

    :sys.resume(attempt)

    assert %{"ok" => @token} = Task.await(during)
    assert %{"ok" => %{"said" => @redacted}} = Task.await(closing)
    assert %{"error" => "lost"} = Task.await(after_close)
    assert {:ok, %{output: %{"said" => @redacted}}} = Dispatch.await(attempt, fixture.close)
    refute_unmasked(Arca.Repo.get!(Arca.Schemas.Execution, id))
  end

  test "an attempt that ends before it closes its run leaves nothing unmasked",
       %{ctx: ctx, fixture: fixture, id: id} do
    assert %{"ok" => @token} = token(fixture)
    emit!(fixture, %{"type" => "text.delta", "text" => "the key is " <> @token})

    attempt = fixture.pid
    ref = Process.monitor(attempt)
    Process.exit(attempt, :kill)
    assert_receive {:DOWN, ^ref, :process, ^attempt, :killed}

    assert %{"error" => "lost"} = complete(fixture, %{"said" => @token})
    assert %{"error" => "lost"} = fail(fixture, "failed with #{@token}")
    assert %{"error" => "lost"} = token(fixture)
    assert %{"error" => "lost"} = push(fixture, %{"text" => @token})

    assert {:error, "Execution attempt ended before it closed"} =
             Dispatch.await(attempt, fixture.close)

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "failed"
    refute_unmasked(row)
    refute_unmasked(live_events())
    refute_unmasked(event_rows(ctx, id))

    assert {:error, :not_found} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")
  end

  test "an attempt whose opener exits stops, sending nothing it held", %{ctx: ctx} do
    test = self()

    {opener, ref} =
      spawn_monitor(fn ->
        fixture = attached!()
        :ok = Cyfr.Execution.Events.subscribe(fixture.execution_id, ctx)
        emit!(fixture, %{"type" => "text.delta", "text" => "held " <> @token})
        send(test, {:opened, fixture})
        send(test, {:live, live_events()})
      end)

    assert_receive {:opened, fixture}, 5_000
    assert_receive {:live, live}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^opener, :normal}
    wait_until(fn -> not Process.alive?(fixture.pid) end)

    assert Enum.map(emitted(live), & &1["text"]) == ["held "]
    assert %{"error" => "lost"} = push(fixture, %{"type" => "note"})
    assert Arca.Repo.get!(Arca.Schemas.Execution, fixture.execution_id).status == "running"
  end

  test "its status names the attempt and its claim, and nothing it masks or holds back",
       %{fixture: fixture} do
    emit!(fixture, %{"type" => "text.delta", "text" => "the key is " <> @token})
    assert %{"ok" => @token} = token(fixture)

    status = :sys.get_status(fixture.pid)
    shown = inspect(status, limit: :infinity, printable_limit: :infinity)

    assert shown =~ fixture.attempt
    assert shown =~ fixture.runner
    refute_unmasked(status)
    refute_bytes(status)

    state = :sys.get_state(fixture.pid)
    assert map_size(state.secrets) == 1
    assert map_size(state.emit.held) == 1
    refute_unmasked(state)
    refute_unmasked(state.emit)
  end

  test "a crash report shows neither a credential, the held text nor the call that crashed it",
       %{fixture: fixture} do
    emit!(fixture, %{"type" => "text.delta", "text" => "the key is " <> @token})
    assert %{"ok" => @token} = token(fixture)
    ref = Process.monitor(fixture.pid)

    # A delta list that is not a list raises inside the call.
    caller = AttemptFixtures.caller(fixture)

    log =
      capture_log(fn ->
        assert {:error, :lost} =
                 Cyfr.Execution.Attempt.call(fixture.execution_id, caller, {:push_deltas, @field})

        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
        Process.sleep(100)
      end)

    assert log =~ "Cyfr.Execution.Attempt"
    refute_unmasked(log)
  end

  # ---------------------------------------------------------------------------

  # An attempt whose edge binds a vault entry holding the field and an OAuth
  # bundle whose access token is the token.
  defp attached! do
    AttemptFixtures.attached!(
      vault: %{kind: "oauth", fields: %{"KEY" => @field}, oauth: %{"access_token" => @token}}
    )
  end

  defp token(fixture),
    do: AttemptFixtures.call(fixture, "oauth_token", %{"provider" => "google"})

  defp push(fixture, event) do
    AttemptFixtures.call(fixture, "push_deltas", %{
      "deltas" => [AttemptFixtures.delta(fixture, Jason.encode!(event))]
    })
  end

  defp emit!(fixture, event) do
    %{"ok" => [reply]} = push(fixture, event)
    Jason.decode!(reply)
  end

  defp complete(fixture, output) do
    AttemptFixtures.call(fixture, "complete", %{
      "outcome" => AttemptFixtures.outcome(fixture, "completed", %{"output" => output})
    })
  end

  defp fail(fixture, error) do
    AttemptFixtures.call(fixture, "fail", %{
      "outcome" => AttemptFixtures.outcome(fixture, "failed", %{"error" => error})
    })
  end

  defp queued(pid), do: pid |> Process.info(:message_queue_len) |> elem(1)

  defp live_events do
    receive do
      %Cyfr.Bus.ExecutionEvent{} = event -> [Cyfr.Bus.ExecutionEvent.event(event) | live_events()]
    after
      200 -> []
    end
  end

  defp emitted(events), do: for(%{type: "emit", data: data} <- events, do: data)

  defp event_rows(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), id, 0)
    Enum.map(rows, &%{type: &1.type, data: Arca.ExecutionEvents.data(&1)})
  end

  # The raw term, not only its inspection: no binary in it carries a secret.
  defp refute_bytes(term) do
    bytes = :erlang.term_to_binary(term)

    for secret <- [@token, @field] do
      assert :binary.match(bytes, secret) == :nomatch
    end
  end

  defp refute_unmasked(term) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- [@token, @field] do
      refute text =~ secret, "#{inspect(secret)} left the run unmasked in: #{text}"
    end
  end
end
