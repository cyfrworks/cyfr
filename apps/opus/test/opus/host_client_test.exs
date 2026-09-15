# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClientTest do
  @moduledoc """
  A runner's client reaches its attempt only through `transport/2`, and only
  strings cross it: a signed header, a JSON body naming the operation, and
  a JSON answer. Every host call this client makes goes that way. A
  client's inspection shows its attempt and never its keys.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Opus.HostClient

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  # Every call of `Cyfr.Execution.Host.call/2` this process makes while `fun`
  # runs, with what it answered, as a tracer process saw them.
  defp crossings(fun) do
    pattern = {Code.ensure_loaded!(Cyfr.Execution.Host), :call, 2}
    test = self()
    tracer = spawn_link(fn -> trace_loop([]) end)
    1 = :erlang.trace_pattern(pattern, [{:_, [], [{:return_trace}]}], [:global])
    1 = :erlang.trace(test, true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(test, false, [:call])
      :erlang.trace_pattern(pattern, false, [:global])
    end

    send(tracer, {:done, test})
    assert_receive {:crossings, crossings}, 1_000
    crossings
  end

  defp trace_loop(seen) do
    receive do
      {:trace, _pid, :call, {Cyfr.Execution.Host, :call, [header, body]}} ->
        trace_loop([{:call, header, body} | seen])

      {:trace, _pid, :return_from, {Cyfr.Execution.Host, :call, 2}, answer} ->
        trace_loop([{:answer, answer} | seen])

      {:done, test} ->
        send(test, {:crossings, pair(Enum.reverse(seen))})
    end
  end

  defp pair([{:call, header, body}, {:answer, answer} | rest]),
    do: [{header, body, answer} | pair(rest)]

  defp pair([]), do: []

  test "every host call crosses the transport as a header, a JSON body and a JSON answer" do
    attempt = AttemptFixtures.attached!(attach: false)
    client = HostClient.new(attempt.keys)

    crossed =
      crossings(fn ->
        assert {:ok, %{}} = HostClient.attach(client, attempt.assignment)
        assert {:ok, %{}} = HostClient.renew(client, [client.attempt])
        assert {:ok, [_reply]} = HostClient.push_deltas(client, [~s({"type":"note"})])
        assert {:error, {:guest_error, _, _}} = HostClient.oauth_token(client, "google")
        assert :ok = HostClient.take_rate(client, "http:" <> attempt.component_ref)

        assert {:error, {:guest_error, "action_denied", _}} =
                 HostClient.storage(client, :read, %{"path" => "data/a.txt"})

        assert {:error, :not_found} =
                 HostClient.fetch_artifact(client, Cyfr.Digest.sha256("not the component"))

        assert :ok = HostClient.record_denial(client, "invalid_json", "Invalid JSON request")
        assert {:ok, %{"done" => true}} = HostClient.complete(client, %{"done" => true})
        assert {:error, :lost} = HostClient.fail(client, "after the close")
      end)

    ops =
      for {header, body, answer} <- crossed do
        assert is_binary(header) and String.starts_with?(header, "v1 kind=call ")
        assert is_binary(body) and is_binary(answer)
        assert %{"op" => op, "args" => %{}} = Jason.decode!(body)
        assert %{} = decoded = Jason.decode!(answer)
        assert Map.has_key?(decoded, "ok") or Map.has_key?(decoded, "error")
        op
      end

    assert ops ==
             ~w(attach renew push_deltas oauth_token take_rate storage fetch_artifact record_denial complete fail)
  end

  test "a client's inspection names its attempt and not its keys" do
    attempt = AttemptFixtures.attached!(attach: false)
    client = HostClient.new(attempt.keys)
    shown = inspect(client, limit: :infinity)

    assert shown =~ attempt.attempt
    refute shown =~ "_key:"

    for key <- [attempt.keys.call, attempt.keys.seal],
        do: refute(shown =~ inspect(key, limit: :infinity))

    Cyfr.Execution.Attempt.refuse(attempt.pid, "not started")
  end

  test "a client whose key is not its attempt's is answered lost" do
    attempt = AttemptFixtures.attached!()
    client = HostClient.new(%{attempt.keys | call: :crypto.strong_rand_bytes(32)}, attempt.runner)

    assert {:error, :lost} = HostClient.push_deltas(client, [~s({"type":"note"})])
    assert {:error, :lost} = HostClient.renew(client, [client.attempt])
  end
end
