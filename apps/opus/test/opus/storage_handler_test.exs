# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StorageHandlerTest do
  @moduledoc """
  The runner's storage import is dispatch only: it bounds and parses the
  guest's request, hands the operation to its attempt's host client, and
  hands CYFR's answer back to the guest as JSON. A request that does not
  parse never reaches CYFR; an attempt that no longer holds its row is a
  storage_error; every call fires its telemetry. What an operation may
  reach is `Cyfr.Execution.GuestStorageTest`'s.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Opus.{HostClient, StorageHandler}
  alias Opus.Test.EdgeFixtures

  @ref "catalyst:local.files:0.1.0"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    test_dir =
      Path.join(System.tmp_dir!(), "storage_handler_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    edge =
      EdgeFixtures.edge(paths: ["data/"], actions: ["read", "write", "list", "delete", "exists"])

    attempt = AttemptFixtures.attached!(authority: %{Cyfr.Authority.zero() | resources: edge})

    {:ok, attempt: attempt, host: HostClient.new(attempt.keys, attempt.runner, attempt.boot)}
  end

  defp call(host, request, limits \\ nil) do
    {:fn, call} =
      StorageHandler.build_storage_imports(limits, host, @ref)["cyfr:storage/files@0.1.0"]["call"]

    request |> encode() |> call.() |> Jason.decode!()
  end

  defp encode(request) when is_binary(request), do: request
  defp encode(request), do: Jason.encode!(request)

  defp write(path, text),
    do: %{"action" => "write", "path" => path, "content" => Base.encode64(text)}

  test "an operation runs on CYFR and its answer reaches the guest with its status", %{
    attempt: attempt,
    host: host
  } do
    assert %{"status" => "ok", "path" => "data/a.txt", "written" => true, "size" => 5} =
             call(host, write("data/a.txt", "hello"))

    assert {:ok, "hello"} = Arca.get(attempt.ctx, ["data", "a.txt"])

    assert %{"status" => "ok", "content" => content, "encoding" => "base64"} =
             call(host, %{"action" => "read", "path" => "data/a.txt"})

    assert Base.decode64!(content) == "hello"

    assert %{"status" => "ok", "path" => "data", "files" => ["a.txt"]} =
             call(host, %{"action" => "list", "path" => "data"})

    # A listing without a path names the scope listing, which a `data/`
    # grant does not reach.
    for action <- ["list", "exists"] do
      assert %{"error" => %{"message" => "Storage path '' is not allowed by policy."}} =
               call(host, %{"action" => action})
    end
  end

  test "CYFR's refusal reaches the guest as its typed error", %{host: host} do
    assert %{"error" => %{"type" => "storage_path_denied", "message" => message}} =
             call(host, write("aqua/agent.json", "{}"))

    assert message =~ "must start with"

    assert %{"error" => %{"type" => "action_denied"}} =
             call(host, %{"action" => "append", "path" => "data/a.txt", "content" => "eA=="})
  end

  test "a request that does not parse is refused without a host call", %{host: host} do
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
      assert %{"error" => %{"type" => ^type, "message" => message}} =
               call(%{host | call_key: :crypto.strong_rand_bytes(32)}, request)

      assert message =~ fragment
    end
  end

  test "a request past the envelope bound is refused before it is parsed" do
    limits = %Cyfr.Limits{max_request_size: 16, max_response_size: 16}
    edge = EdgeFixtures.edge(paths: ["data/"], actions: ["write"])

    attempt =
      AttemptFixtures.attached!(
        authority: %{Cyfr.Authority.zero() | resources: edge},
        limits: limits
      )

    host = HostClient.new(attempt.keys, attempt.runner, attempt.boot)

    huge =
      ~s({"action": "write", "path": "data/x.txt", "content": "#{String.duplicate("A", 200_000)}"})

    assert %{"error" => %{"type" => "request_too_large"}} = call(host, huge, limits)

    # A payload past the consented size but within the envelope is refused
    # by CYFR, under the attempt's limits, on its decoded bytes.
    assert %{"error" => %{"type" => "request_too_large", "message" => "Storage write" <> _}} =
             call(host, write("data/y.txt", String.duplicate("z", 24)), limits)
  end

  test "an attempt that no longer holds its row reads and writes nothing", %{
    attempt: attempt,
    host: host
  } do
    assert %{"written" => true} = call(host, write("data/before.txt", "kept"))
    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(attempt.ctx, attempt.execution_id)

    for request <- [
          write("data/after.txt", "late"),
          write("data/before.txt", "overwritten"),
          %{"action" => "read", "path" => "data/before.txt"}
        ] do
      assert %{"error" => %{"type" => "storage_error", "message" => message}} =
               call(host, request)

      assert message =~ "not current"
    end

    refute Arca.exists?(attempt.ctx, ["data", "after.txt"])
    assert {:ok, "kept"} = Arca.get(attempt.ctx, ["data", "before.txt"])
  end

  test "every call fires its telemetry with the action and its outcome", %{host: host} do
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

    call(host, write("data/t.txt", "x"))

    assert_receive {:storage_call, %{duration_ms: duration},
                    %{component_ref: @ref, action: "write", status: :ok}}

    assert is_integer(duration)

    call(host, write("aqua/t.txt", "x"))
    assert_receive {:storage_call, _, %{action: "write", status: :error}}

    call(host, "not json")
    assert_receive {:storage_call, _, %{action: "unknown", status: :error}}
  end
end
