# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.InputsImportTest do
  @moduledoc """
  A catalyst's `cyfr:model/inputs` import carries each call to the host:
  `next` and `sent` are the host calls `input_next` and `input_sent`, and
  the guest is handed what the host answered: an input as its id and its
  content's JSON, none, or a refusal as its code. A lost answer is asked
  once more, since a read moves nothing and a report marks once, and an
  answer that is no input is lost to the guest. A reagent is given no
  inputs.

  The guest is `test_wasm/hostile/inputs_probe`, run by the runtime in this
  VM against a scripted host.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Test.ScriptedHost

  @probe File.read!(
           Path.expand("../../support/runtime/test_wasm/hostile/inputs_probe.wasm", __DIR__)
         )

  @input %{
    "id" => "evt_01a0-input.1",
    "content" => [%{"type" => "text", "text" => "Still waiting on the run?"}]
  }

  defp run(attempt) do
    Locus.Runtime.Engine.execute_component(@probe, %{},
      component_type: :catalyst,
      component_ref: "catalyst:local.inputs-probe:0.1.0",
      host: attempt.client,
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.limits(Prima.Authority.zero())
    )
  end

  defp input_requests(host) do
    for %{op: "input_" <> _ = op, args: args} <- ScriptedHost.requests(host), do: {op, args}
  end

  defp catalyst do
    host = ScriptedHost.start!()
    {host, ScriptedHost.attempt!(host, component_type: :catalyst)}
  end

  test "an input is handed to the guest as its id and content, and its report is the host's" do
    {host, attempt} = catalyst()
    ScriptedHost.script(host, "input_next", {:ok, @input})
    ScriptedHost.script(host, "input_sent", {:ok, true})

    content_bytes = byte_size(Jason.encode!(@input["content"]))

    assert {:ok,
            %{
              "status" => 200,
              "data" => %{
                "next" => "ok",
                "id" => "evt_01a0-input.1",
                "content_bytes" => ^content_bytes,
                "sent" => "ok"
              }
            }} = run(attempt)

    assert input_requests(host) == [
             {"input_next", %{}},
             {"input_sent", %{"id" => "evt_01a0-input.1"}}
           ]
  end

  test "none is handed to the guest as none, and nothing is reported" do
    {host, attempt} = catalyst()
    ScriptedHost.script(host, "input_next", {:ok, nil})

    assert {:ok, %{"data" => %{"next" => "none"} = data}} = run(attempt)
    assert map_size(data) == 1
    assert input_requests(host) == [{"input_next", %{}}]
  end

  test "a refusal reaches the guest as its code" do
    for {answer, code} <- [
          {{:error, :lost}, "lost"},
          {{:error, :unavailable}, "unavailable"},
          {{:error, {:guest_error, "invalid_request", "The input does not read (id)."}},
           "invalid_request"}
        ] do
      {host, attempt} = catalyst()
      ScriptedHost.script(host, "input_next", answer)

      assert {:ok, %{"data" => %{"next" => ^code}}} = run(attempt)
      assert [{"input_next", _args}] = input_requests(host)
    end
  end

  test "a report the host refuses reaches the guest as its code" do
    {host, attempt} = catalyst()
    ScriptedHost.script(host, "input_next", {:ok, @input})
    ScriptedHost.script(host, "input_sent", {:error, :unavailable})

    assert {:ok, %{"data" => %{"next" => "ok", "sent" => "unavailable"}}} = run(attempt)
  end

  test "a lost answer is asked once more: a read moves nothing, and a report marks once" do
    {host, attempt} = catalyst()
    ScriptedHost.script(host, "input_next", [:drop, {:ok, @input}])
    ScriptedHost.script(host, "input_sent", [:drop, {:ok, true}])

    assert {:ok, %{"data" => %{"next" => "ok", "sent" => "ok"}}} = run(attempt)
    assert [_first, _again] = ScriptedHost.requests(host, "input_next")
    assert [_first, _again] = ScriptedHost.requests(host, "input_sent")
  end

  test "an answer that is no input is lost to the guest" do
    for answer <- [
          %{"id" => "evt x", "content" => "hi"},
          %{"id" => "evt_x", "content" => [%{"type" => "image", "url" => "https://x.test/a"}]},
          "evt_x"
        ] do
      {host, attempt} = catalyst()
      ScriptedHost.script(host, "input_next", {:ok, answer})

      assert {:ok, %{"data" => %{"next" => "lost"}}} = run(attempt)
      assert ScriptedHost.requests(host, "input_sent") == []
    end
  end

  test "a reagent is given no inputs, so one importing them does not instantiate" do
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
