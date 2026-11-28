# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Locus.Runtime.RunnerEventsTest do
  @moduledoc """
  A runner's operator events reach the control plane, which emits them
  (`Opus.Host.RunnerEvents`): the runner writes each on its control
  channel, its worker service forwards them in a batch, and CYFR's
  listener reads the batch whole. What a guest shapes of an event, the
  tool and action it names here, is cut to its first 256 bytes on a
  character boundary however long it is and whatever bytes it holds,
  escaped or not, so every event the runner writes is one its service
  reads, and no guest can have its runner retired, or its run fail, by
  what it names.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Cyfr.Test.{RuntimeService, TwoServices}
  alias Locus.Runtime.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap

  @moduletag timeout: 120_000

  @event [:cyfr, :locus, :runtime, :mcp_tool, :call]
  @max_string_bytes Prima.RunnerControl.max_event_string_bytes()

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path =
      Path.join(System.tmp_dir!(), "runner_events_#{System.unique_integer([:positive])}")

    previous = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    unique = System.unique_integer([:positive])

    {:ok, athanor} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        name: "Events #{unique}",
        slug: "events-#{unique}",
        owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
        created_by: "system"
      })

    ctx = %{Sanctum.TestContext.local(:api) | athanor_id: athanor.id}
    Sanctum.TestContext.ready!(ctx.athanor_id)

    test = self()
    id = "runner-events-test-#{unique}"
    :ok = :telemetry.attach(id, @event, &__MODULE__.forward/4, test)

    on_exit(fn ->
      :telemetry.detach(id)
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      if previous,
        do: Application.put_env(:arca, :base_path, previous),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Probe.publish_probe!(ctx)
    {:ok, _bootstrapped} = Bootstrap.run(ctx)
    {:ok, ctx: ctx}
  end

  @doc false
  def forward(_event, measurements, metadata, test),
    do: send(test, {:tool_event, measurements, metadata})

  # A call of a tool its consent does not grant, named `tool` `action`:
  # CYFR refuses it, and the runner reports the call.
  defp call(tool, action),
    do: %{"call" => %{"tool" => tool, "action" => action, "args" => %{}}}

  # `text` cut as the runner cuts an event's string: its first bytes up to
  # the bound, back to the last character boundary.
  defp cut(text) when byte_size(text) <= @max_string_bytes, do: text
  defp cut(text), do: boundary(binary_part(text, 0, @max_string_bytes))

  defp boundary(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: boundary(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  test "what a guest names in an event is cut on a character boundary, whatever it holds, and " <>
         "every event reaches CYFR without its runner retired",
       %{ctx: ctx} do
    names = [
      # 257 bytes: its first 256 kept.
      {String.duplicate("a", 200), String.duplicate("b", 56)},
      # Its 256th byte the first of a two-byte character: cut before it.
      {String.duplicate("c", 200), String.duplicate("d", 54) <> "é" <> "e"},
      # Inside a four-byte character.
      {String.duplicate("f", 200), String.duplicate("g", 54) <> "𝄞"},
      # Quotes and backslashes the line escapes, two bytes each.
      {String.duplicate(~S("), 150), String.duplicate("\\", 150)},
      # Control bytes the line escapes, six bytes each.
      {String.duplicate(<<1>>, 150), String.duplicate(<<31>>, 150)}
    ]

    execution_id = Prima.UUID7.execution_id()

    {:ok, result} =
      Opus.run_root(
        ctx,
        :default,
        Probe.probe_ref(),
        %{"op" => "steps", "steps" => Enum.map(names, fn {tool, action} -> call(tool, action) end)},
        execution_id: execution_id
      )

    # Every call was refused, as CYFR refuses a tool its consent lacks,
    # and the run completed all the same.
    assert result.status == :completed
    assert length(result.output["results"]) == length(names)

    for {tool, action} <- names do
      expected = cut(tool <> "." <> action)
      assert byte_size(expected) <= @max_string_bytes
      assert_receive {:tool_event, %{duration_ms: ms}, metadata}, 10_000
      assert is_integer(ms)

      assert metadata == %{
               execution_id: execution_id,
               tool_action: expected,
               status: :error
             }
    end

    # The runner was never retired for what its guest named: it completed
    # clean and is kept, and no runner's exit was reported.
    wait_until(fn -> RuntimeService.status().attempts == [] end, 10_000)
    assert %{runners: %{busy: 0, tainted: 0, idle: idle}} = RuntimeService.status()
    assert idle >= 1
  end
end
