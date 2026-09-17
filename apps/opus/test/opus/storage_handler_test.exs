# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StorageHandlerTest do
  @moduledoc """
  The runner's storage import is dispatch only: it bounds and parses the
  guest's request, hands the operation to its attempt's host client, and
  hands CYFR's answer back to the guest as JSON. A request that does not
  parse never reaches CYFR; every refusal CYFR answers, and a lost answer,
  reaches the guest as a typed error; every call fires its telemetry. What
  an operation may reach is CYFR's to decide.
  """

  use ExUnit.Case, async: true

  alias Opus.StorageHandler
  alias Opus.Test.ScriptedHost

  @ref "catalyst:local.files:0.1.0"

  setup do
    host = ScriptedHost.start!()
    {:ok, host: host, client: ScriptedHost.attempt!(host, component_ref: @ref).client}
  end

  defp call(client, request, limits \\ nil) do
    {:fn, call} =
      StorageHandler.build_storage_imports(limits, client, @ref)["cyfr:storage/files@0.1.0"][
        "call"
      ]

    request |> encode() |> call.() |> Jason.decode!()
  end

  defp encode(request) when is_binary(request), do: request
  defp encode(request), do: Jason.encode!(request)

  defp write(path, text),
    do: %{"action" => "write", "path" => path, "content" => Base.encode64(text)}

  test "an operation runs on CYFR and its answer reaches the guest with its status", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "storage", fn
      %{"action" => "write", "path" => path, "content" => content}, _caller ->
        {:ok, %{"path" => path, "written" => true, "size" => byte_size(Base.decode64!(content))}}

      %{"action" => "read"}, _caller ->
        {:ok, %{"content" => Base.encode64("hello"), "encoding" => "base64"}}

      %{"action" => "list", "path" => "data"}, _caller ->
        {:ok, %{"path" => "data", "files" => ["a.txt"]}}
    end)

    assert %{"status" => "ok", "path" => "data/a.txt", "written" => true, "size" => 5} =
             call(client, write("data/a.txt", "hello"))

    assert %{"status" => "ok", "content" => content, "encoding" => "base64"} =
             call(client, %{"action" => "read", "path" => "data/a.txt"})

    assert Base.decode64!(content) == "hello"

    assert %{"status" => "ok", "path" => "data", "files" => ["a.txt"]} =
             call(client, %{"action" => "list", "path" => "data"})

    # The guest request's members other than `action` cross as the call's
    # args, `action` naming the operation.
    assert [write, read, list] = ScriptedHost.requests(host, "storage")
    assert %{"action" => "write", "path" => "data/a.txt", "content" => _} = write.args
    assert read.args == %{"action" => "read", "path" => "data/a.txt"}
    assert list.args == %{"action" => "list", "path" => "data"}
  end

  test "a listing without a path names the scope listing", %{host: host, client: client} do
    ScriptedHost.script(host, "storage", fn args, _caller -> {:ok, %{"echo" => args}} end)

    for action <- ["list", "exists"] do
      assert %{"status" => "ok", "echo" => %{"action" => ^action, "path" => ""}} =
               call(client, %{"action" => action})
    end
  end

  test "CYFR's refusal reaches the guest as its typed error", %{host: host, client: client} do
    ScriptedHost.script(host, "storage", fn
      %{"path" => "aqua/" <> _}, _caller ->
        {:error, {:guest_error, "storage_path_denied", "Storage path must start with data/"}}

      %{"action" => "append"}, _caller ->
        {:error, {:guest_error, "action_denied", "append is not consented"}}
    end)

    assert %{"error" => %{"type" => "storage_path_denied", "message" => message}} =
             call(client, write("aqua/agent.json", "{}"))

    assert message =~ "must start with"

    assert %{"error" => %{"type" => "action_denied"}} =
             call(client, %{"action" => "append", "path" => "data/a.txt", "content" => "eA=="})
  end

  test "a request that does not parse is refused without a host call", %{
    host: host,
    client: client
  } do
    for {request, type, fragment} <- [
          {"not json", "invalid_json", "Invalid JSON"},
          {~s({"path": "data/test.txt"}), "invalid_request", "'action'"},
          {~s([1, 2, 3]), "invalid_request", "'action'"},
          {~s({"action": "read"}), "invalid_request", "'path'"},
          {~s({"action": "write", "path": 42}), "invalid_request", "'path'"},
          {~s({"action": "write", "path": "data/a.txt", "content": 42}), "invalid_request",
           "content"},
          {~s({"action": "truncate", "path": "data/test.txt"}), "unknown_action", "truncate"}
        ] do
      assert %{"error" => %{"type" => ^type, "message" => message}} = call(client, request)
      assert message =~ fragment
    end

    assert ScriptedHost.requests(host) == []
  end

  test "a request past the envelope bound is refused before it is parsed", %{
    host: host,
    client: client
  } do
    limits = %Cyfr.Limits{max_request_size: 16, max_response_size: 16}

    huge =
      ~s({"action": "write", "path": "data/x.txt", "content": "#{String.duplicate("A", 200_000)}"})

    assert %{"error" => %{"type" => "request_too_large"}} = call(client, huge, limits)
    assert ScriptedHost.requests(host) == []
  end

  test "an attempt that no longer holds its row, an unavailable store and a lost answer are each a storage_error",
       %{host: host, client: client} do
    ScriptedHost.script(host, "storage", [{:error, :lost}, {:error, :unavailable}, :drop])

    assert %{"error" => %{"type" => "storage_error", "message" => lost}} =
             call(client, write("data/after.txt", "late"))

    assert lost =~ "not current"

    assert %{"error" => %{"type" => "storage_error", "message" => unavailable}} =
             call(client, write("data/after.txt", "late"))

    assert unavailable =~ "unavailable"

    assert %{"error" => %{"type" => "storage_error", "message" => uncertain}} =
             call(client, write("data/after.txt", "late"))

    assert uncertain =~ "lost"
  end

  test "every call fires its telemetry with the action and its outcome", %{
    host: host,
    client: client
  } do
    test = self()
    handler = "storage-handler-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cyfr, :opus, :storage, :call],
      fn _event, measurements, metadata, _config ->
        send(test, {:storage_call, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    ScriptedHost.script(host, "storage", [
      {:ok, %{"written" => true}},
      {:error, {:guest_error, "storage_path_denied", "denied"}}
    ])

    call(client, write("data/t.txt", "x"))

    assert_receive {:storage_call, %{duration_ms: duration},
                    %{component_ref: @ref, action: "write", status: :ok}}

    assert is_integer(duration)

    call(client, write("aqua/t.txt", "x"))
    assert_receive {:storage_call, _, %{action: "write", status: :error}}

    call(client, "not json")
    assert_receive {:storage_call, _, %{action: "unknown", status: :error}}
  end
end
