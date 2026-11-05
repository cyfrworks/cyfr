# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.PipeImportTest do
  @moduledoc """
  A catalyst built against the catalyst world's `cyfr:process/pipe`
  import instantiates, and every call of its pipe answers
  `err("not_built")` without a host call: a program's pipe is not built
  yet.

  The guest is `test_wasm/hostile/pipe_probe`, run by the runtime in this
  VM against a scripted host.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Test.ScriptedHost

  @probe File.read!(
           Path.expand("../../support/runtime/test_wasm/hostile/pipe_probe.wasm", __DIR__)
         )

  test "a catalyst importing the pipe runs, and each pipe call answers not_built" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)

    assert {:ok, %{"status" => 200, "data" => %{"pipe" => "NNNN"}}} =
             Locus.Runtime.Engine.execute_component(@probe, %{"operation" => "probe"},
               component_type: :catalyst,
               component_ref: "catalyst:local.pipe-probe:0.1.0",
               host: attempt.client,
               authority: Prima.Authority.zero(),
               limits: Prima.Authority.limits(Prima.Authority.zero())
             )

    assert ScriptedHost.requests(host) == []
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
