# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.FormulaHandlerVectorsTest do
  @moduledoc """
  A formula's tool call that CYFR refuses with a setup remediation answers
  the guest the shared vectors' setup envelope
  (`tests/fixtures/guest_error.json`'s `setup_required` cases, which
  Prima's test reads too): `Locus.Runtime.FormulaHandler` hands on the
  type, the sentence and the remediation CYFR answered, as one error
  envelope, on a scripted host that answers the call as CYFR would. A
  storage call CYFR refuses with a guest error answers the envelope of
  each of the vectors' `encode_error` cases of a storage type whose
  message is a sentence: `Locus.Runtime.StorageHandler` hands on the
  type and the sentence CYFR answered. A fetch whose pin CYFR refuses for
  want of a flow answers the envelope of the vectors' `flow_blocked`
  case: `Locus.Runtime.HttpHandler` names the host CYFR refused, as
  Prima's reader of the same case answers it.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.{FormulaHandler, HttpHandler, StorageHandler}
  alias Locus.Runtime.Test.{EdgeFixtures, ScriptedHost}

  @vectors Path.expand("../../../../../tests/fixtures/guest_error.json", __DIR__)

  test "a storage call CYFR refuses answers every storage case's envelope" do
    cases =
      for %{"type" => "storage_" <> _, "message" => message} = vector <-
            @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("encode_error"),
          is_binary(message),
          do: vector

    assert "storage_unavailable" in Enum.map(cases, & &1["type"])

    for %{"why" => why, "type" => type, "message" => message, "answer" => answer} <- cases do
      host = ScriptedHost.start!()
      ScriptedHost.script(host, "storage", {:error, {:guest_error, type, message}})
      attempt = ScriptedHost.attempt!(host)

      request =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/a.txt",
          "content" => Base.encode64("x")
        })

      json = StorageHandler.execute(request, nil, attempt.client, "catalyst:local.files:0.1.0")

      assert Jason.decode!(json) == answer, why
      assert [%{args: %{"action" => "write"}}] = ScriptedHost.requests(host, "storage"), why
    end
  end

  test "a fetch CYFR refuses for want of a flow answers the flow case's envelope" do
    assert [%{"why" => why, "message" => message, "answer" => answer}] =
             for(
               %{"type" => "flow_blocked"} = vector <-
                 @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("encode_error"),
               do: vector
             )

    # The case's host is the one its sentence names.
    [_, host_name] = Regex.run(~r/^HTTP egress to (\S+) refused/, message)
    edge = EdgeFixtures.edge(domains: [host_name], methods: ["GET"])
    host = ScriptedHost.start!()
    ScriptedHost.script(host, "egress_pin", {:error, :flow})
    attempt = ScriptedHost.attempt!(host)

    json =
      %{"method" => "GET", "url" => "https://#{host_name}/notes", "headers" => %{}, "body" => ""}
      |> Jason.encode!()
      |> HttpHandler.execute(
        edge,
        EdgeFixtures.limits(),
        attempt.client,
        "catalyst:local.x:1.0.0"
      )

    assert Jason.decode!(json) == answer, why
    assert [%{args: %{"url" => url}}] = ScriptedHost.requests(host, "egress_pin"), why
    assert URI.parse(url).host == host_name, why

    # CYFR recorded the denial as it refused the pin: the engine records none.
    assert ScriptedHost.requests(host, "record_denial") == [], why
  end

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
