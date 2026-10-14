# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.FormulaHandlerVectorsTest do
  @moduledoc """
  A formula's tool call that CYFR refuses with a setup remediation answers
  the guest the shared vectors' setup envelope
  (`tests/fixtures/guest_error.json`'s `setup_required` cases, which
  Prima's test reads too): `Locus.Runtime.FormulaHandler` hands on the
  type, the sentence and the remediation CYFR answered, as one error
  envelope, on a scripted host that answers the call as CYFR would.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.FormulaHandler
  alias Locus.Runtime.Test.ScriptedHost

  @vectors Path.expand("../../../../../tests/fixtures/guest_error.json", __DIR__)

  test "a call refused with a setup remediation answers every case's envelope" do
    # Read when the test runs: a missing file fails the test.
    cases = @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("setup_required")
    assert length(cases) == 2

    for vector <- cases do
      %{
        "why" => why,
        "remediation" => remediation,
        "message" => message,
        "answer" => answer
      } = vector

      host = ScriptedHost.start!()

      ScriptedHost.script(
        host,
        "tool_call",
        {:error, {:guest_error, "setup_required", message, remediation}}
      )

      attempt = ScriptedHost.attempt!(host, component_type: :formula)
      request = Jason.encode!(%{"tool" => "vault", "action" => "list", "args" => %{}})

      json =
        FormulaHandler.execute(request, attempt.client, limits: Prima.Limits.defaults(:formula))

      assert Jason.decode!(json) == answer, why
      assert [%{args: %{"name" => "vault"}}] = ScriptedHost.requests(host, "tool_call"), why
    end
  end
end
