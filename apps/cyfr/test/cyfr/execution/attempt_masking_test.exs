# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.AttemptMaskingTest do
  @moduledoc """
  A run's attempt is the one place its credentials are masked: the vault
  field unsealed for it and every OAuth token it dispenses are masked in the
  events its guest emits, in the text its emitter still holds when the run
  closes — which goes out before the terminal row — and in the output, the
  result payload, a failure message, the lifecycle events and the answer the
  caller gets. A token asked for while the run closes is either masked or
  never dispensed. An attempt that ends before it closes its run, or whose
  opener exits, leaves nothing unmasked behind.

  The vault field begins with the token, so text that ends in the token is
  held back as the possible start of the field until the token is
  dispensed.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Execution.{Attempt, Close, Record}

  @token "ya29.token-0123456789"
  @field @token <> "-and-field"
  @ref "catalyst:local.masking-probe:0.1.0"
  @redacted "[REDACTED]"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    authority = oauth_authority!(ctx)
    record = Record.new(ctx, @ref, %{"q" => 1}, component_type: :catalyst)
    :ok = Record.write_started(record)

    close = %Close{
      ctx: ctx,
      record: record,
      limits: Cyfr.Authority.limits(authority),
      started: true
    }

    :ok = Cyfr.Execution.Events.subscribe(record.id, ctx)
    {:ok, pid} = open(ctx, authority, record.id, attempt: record.attempt)

    {:ok, ctx: ctx, authority: authority, id: record.id, close: close, attempt: pid}
  end

  test "a dispensed token and the vault field are masked in the events, output, row, payload and answer",
       %{ctx: ctx, id: id, close: close} do
    assert {:ok, @token} = Attempt.dispense_oauth(id, "google")
    assert %{"sequence" => _} = emit!(id, %{"type" => "note", "text" => "#{@token} #{@field}"})

    assert {:ok, result} = Attempt.complete(id, close, %{"said" => "#{@token} / #{@field}"}, %{})
    assert result.output == %{"said" => "#{@redacted} / #{@redacted}"}
    refute_unmasked(result)

    assert [%{"text" => "#{@redacted} #{@redacted}"}] = emitted(live_events())

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "completed"
    refute_unmasked(row)

    assert {:ok, _row, payload} = Arca.ExecutionPayloads.get(ctx, id, "result")
    assert payload =~ @redacted
    refute_unmasked(payload)
    refute_unmasked(Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id))
    refute_unmasked(event_rows(ctx, id))
  end

  test "held text goes out masked with the set as it stands at close, before the terminal row",
       %{ctx: ctx, id: id, close: close} do
    emit!(id, %{"type" => "text.delta", "text" => "the token is " <> @token})
    assert {:ok, @token} = Attempt.dispense_oauth(id, "google")

    assert {:ok, _result} = Attempt.complete(id, close, %{"said" => "done"}, %{})

    live = live_events()
    assert Enum.map(emitted(live), & &1["text"]) == ["the token is ", @redacted]
    refute_unmasked(live)

    tail_at = Enum.find_index(live, &(&1.type == "emit" and &1.data["text"] == @redacted))
    completed_at = Enum.find_index(live, &(&1.type == "execution.completed"))
    assert is_integer(tail_at) and is_integer(completed_at) and tail_at < completed_at

    refute_unmasked(Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id))
  end

  test "the last delta of a stream that never ends reaches the stream before a failed row",
       %{id: id, close: close} do
    emit!(id, %{"type" => "text.delta", "text" => "partial ya29.tok"})

    assert {:error, "upstream failed"} = Attempt.fail(id, close, "upstream failed")

    live = live_events()
    assert Enum.map(emitted(live), & &1["text"]) == ["partial ", "ya29.tok"]
    assert [_, _, %{type: "execution.failed"}] = live
    assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, id)
  end

  test "a failure message is masked in the row, its event and the answer",
       %{ctx: ctx, id: id, close: close} do
    assert {:ok, @token} = Attempt.dispense_oauth(id, "google")

    assert {:error, message} = Attempt.fail(id, close, "upstream said #{@token} for #{@field}")
    assert message == "upstream said #{@redacted} for #{@redacted}"

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows)
    refute_unmasked(live_events())
  end

  test "a token asked for while the run closes is masked, and one asked for after it is never dispensed",
       %{id: id, close: close, attempt: attempt} do
    :sys.suspend(attempt)

    during = Task.async(fn -> Attempt.dispense_oauth(id, "google") end)
    wait_until(fn -> queued(attempt) == 1 end)
    closing = Task.async(fn -> Attempt.complete(id, close, %{"said" => @token}, %{}) end)
    wait_until(fn -> queued(attempt) == 2 end)
    after_close = Task.async(fn -> Attempt.dispense_oauth(id, "google") end)
    wait_until(fn -> queued(attempt) == 3 end)

    :sys.resume(attempt)

    assert {:ok, @token} = Task.await(during)
    assert {:ok, %{output: %{"said" => @redacted}}} = Task.await(closing)
    assert {:error, "the credential store is unavailable"} = Task.await(after_close)
    refute_unmasked(Arca.Repo.get!(Arca.Execution, id))
  end

  test "an attempt that ends before it closes its run leaves nothing unmasked",
       %{ctx: ctx, id: id, close: close, attempt: attempt} do
    assert {:ok, @token} = Attempt.dispense_oauth(id, "google")
    emit!(id, %{"type" => "text.delta", "text" => "the key is " <> @token})

    ref = Process.monitor(attempt)
    Process.exit(attempt, :kill)
    assert_receive {:DOWN, ^ref, :process, ^attempt, :killed}

    assert :lost = Attempt.complete(id, close, %{"said" => @token}, %{})
    assert :lost = Attempt.fail(id, close, "failed with #{@token}")
    assert {:error, _refused} = Attempt.dispense_oauth(id, "google")

    assert %{"error" => %{"type" => "dispatch_error"}} =
             Jason.decode!(Attempt.emit(id, Jason.encode!(%{"text" => @token})))

    assert {:error, "Execution attempt ended before it closed"} = Close.lost(close)

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "failed"
    refute_unmasked(row)
    refute_unmasked(live_events())
    refute_unmasked(event_rows(ctx, id))
    assert {:error, :not_found} = Arca.ExecutionPayloads.get(ctx, id, "result")
  end

  test "an attempt whose opener exits stops, sending nothing it held",
       %{ctx: ctx, authority: authority} do
    id = "exec_orphan_#{System.unique_integer([:positive])}"
    :ok = Cyfr.Execution.Events.subscribe(id, ctx)
    test = self()

    {opener, ref} =
      spawn_monitor(fn ->
        {:ok, attempt} = open(ctx, authority, id)
        emit!(id, %{"type" => "text.delta", "text" => "held " <> @token})
        send(test, {:opened, attempt})
      end)

    assert_receive {:opened, attempt}
    assert_receive {:DOWN, ^ref, :process, ^opener, :normal}
    wait_until(fn -> not Process.alive?(attempt) end)

    assert Enum.map(emitted(live_events()), & &1["text"]) == ["held "]
  end

  # ---------------------------------------------------------------------------

  defp open(ctx, authority, id, opts \\ []) do
    Attempt.open(
      [
        execution_id: id,
        ctx: ctx,
        authority: authority,
        component_ref: @ref,
        secrets: %{"KEY" => @field}
      ] ++ opts
    )
  end

  # An authority whose edge binds a vault entry holding the field and an
  # OAuth bundle whose access token is the token.
  defp oauth_authority!(ctx) do
    {:ok, view} =
      Sanctum.Vault.create(ctx, %{
        name: "masking-#{System.unique_integer([:positive])}",
        kind: "oauth",
        fields: %{"KEY" => @field},
        oauth: %{"access_token" => @token, "token_type" => "bearer"}
      })

    {:ok, entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
    vault = %{entry_id: view.id, binding_digest: digest, projection: nil}
    %{Cyfr.Authority.zero() | resources: %Cyfr.Authority.Blob.Edge{vault: vault}}
  end

  defp emit!(id, event), do: id |> Attempt.emit(Jason.encode!(event)) |> Jason.decode!()

  defp queued(pid), do: pid |> Process.info(:message_queue_len) |> elem(1)

  defp live_events do
    receive do
      {:execution_event, event} -> [event | live_events()]
    after
      200 -> []
    end
  end

  defp emitted(events), do: for(%{type: "emit", data: data} <- events, do: data)

  defp event_rows(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, id, 0)
    Enum.map(rows, &%{type: &1.type, data: Arca.ExecutionEvents.data(&1)})
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
