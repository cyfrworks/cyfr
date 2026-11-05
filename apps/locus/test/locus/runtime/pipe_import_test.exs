# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.PipeImportTest do
  @moduledoc """
  A catalyst's `cyfr:process/pipe` import carries each call to the host:
  `open`, `send`, `recv` and `close` are the host calls `pipe_open`,
  `pipe_send`, `pipe_recv` and `pipe_close`, with the guest's arguments,
  and the guest is handed what the host answered. A refusal reaches the
  guest as its code: a `denied` open, after which the guest makes no other
  pipe call; a send whose answer was lost, which is never asked again and
  is `lost`. A line the backends wire would refuse is refused here,
  `invalid_request`, before any host call. A reagent is given no pipe.

  The guest is `test_wasm/hostile/pipe_probe`, run by the runtime in this
  VM against a scripted host.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Test.ScriptedHost

  @probe File.read!(
           Path.expand("../../support/runtime/test_wasm/hostile/pipe_probe.wasm", __DIR__)
         )

  @session "pls_01a09fee-3d4e-7f50-9b6c-7d8e9f0a1b2c"

  defp run(attempt, line) do
    Locus.Runtime.Engine.execute_component(@probe, %{"line" => line},
      component_type: :catalyst,
      component_ref: "catalyst:local.pipe-probe:0.1.0",
      host: attempt.client,
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.limits(Prima.Authority.zero())
    )
  end

  defp pipe_requests(host) do
    for %{op: "pipe_" <> _ = op, args: args} <- ScriptedHost.requests(host), do: {op, args}
  end

  defp script_round_trip(host) do
    ScriptedHost.script(host, "pipe_open", {:ok, %{"session" => @session, "resumed" => false}})
    ScriptedHost.script(host, "pipe_send", {:ok, true})

    ScriptedHost.script(
      host,
      "pipe_recv",
      {:ok,
       %{
         "lines" => [%{"seq" => 1, "text" => "hello back"}, %{"seq" => 2, "text" => "more"}],
         "dropped" => 3,
         "running" => true
       }}
    )

    ScriptedHost.script(host, "pipe_close", {:ok, true})
  end

  test "each pipe call is the host call of its name, and the guest gets its answer" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)

    assert {:ok,
            %{
              "status" => 200,
              "data" => %{
                "open" => "ok",
                "session" => @session,
                "resumed" => false,
                "send" => "ok",
                "recv" => "ok",
                "count" => 2,
                "dropped" => 3,
                "line" => "hello back",
                "running" => true,
                "close" => "ok"
              }
            }} = run(attempt, "hello")

    assert pipe_requests(host) == [
             {"pipe_open", %{"need" => "coder", "key" => "chat_1", "argv" => ["--flag"]}},
             {"pipe_send", %{"session" => @session, "lines" => ["hello"]}},
             {"pipe_recv", %{"session" => @session, "after" => 0, "max_wait_ms" => 1000}},
             {"pipe_close", %{"session" => @session}}
           ]
  end

  test "a denied open is handed to the guest, which makes no other pipe call" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)
    ScriptedHost.script(host, "pipe_open", {:error, :denied})

    assert {:ok, %{"status" => 200, "data" => data}} = run(attempt, "hello")
    assert data == %{"open" => "denied"}
    assert [{"pipe_open", _args}] = pipe_requests(host)
  end

  test "a guest error is handed to the guest by its type" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)

    ScriptedHost.script(
      host,
      "pipe_send",
      {:error, {:guest_error, "ended", "The session's program ended."}}
    )

    assert {:ok, %{"data" => %{"open" => "ok", "send" => "ended", "close" => "ok"}}} =
             run(attempt, "hello")
  end

  test "a send whose answer is lost is not asked again, and is lost to the guest" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)
    ScriptedHost.script(host, "pipe_send", :drop)

    assert {:ok, %{"data" => %{"open" => "ok", "send" => "lost", "recv" => "ok"}}} =
             run(attempt, "hello")

    assert [_one] = ScriptedHost.requests(host, "pipe_send")
  end

  test "a lost recv answer is asked once more by the same after" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)

    ScriptedHost.script(host, "pipe_recv", [
      :drop,
      {:ok, %{"lines" => [], "dropped" => 0, "running" => false}}
    ])

    assert {:ok, %{"data" => %{"recv" => "ok", "count" => 0, "running" => false} = data}} =
             run(attempt, "hello")

    refute Map.has_key?(data, "line")

    assert [%{args: %{"after" => 0}}, %{args: %{"after" => 0}}] =
             ScriptedHost.requests(host, "pipe_recv")
  end

  test "a line holding a newline is refused before it crosses, as invalid_request" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    script_round_trip(host)

    assert {:ok, %{"data" => %{"open" => "ok", "send" => "invalid_request", "recv" => "ok"}}} =
             run(attempt, "two\nlines")

    assert ScriptedHost.requests(host, "pipe_send") == []
  end

  test "a reagent is given no pipe, so one importing it does not instantiate" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :reagent)

    assert {:error, "Component instantiation failed: " <> _reason} =
             Locus.Runtime.Engine.execute_component(@probe, %{},
               component_type: :reagent,
               host: attempt.client,
               authority: Prima.Authority.zero(),
               limits: Prima.Authority.limits(Prima.Authority.zero())
             )
  end
end
