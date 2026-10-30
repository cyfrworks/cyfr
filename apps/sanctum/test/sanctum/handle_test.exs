# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.HandleTest do
  @moduledoc """
  A handle resolved at the registry this deployment names: one exact
  handle asked of `GET /v1/handles/{handle}`, its answer read as
  `cyfr-handle/v1` for the handle and registry asked, and every other
  answer a typed refusal. The answers are the shared vector file's
  (`tests/fixtures/registry_wire.json`), rehosted on the stub's host.
  """

  # The registry's address is process-wide configuration.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.HandleAnswer
  alias Sanctum.Handle
  alias Sanctum.Test.RegistryStub

  @vectors "../../../../tests/fixtures/registry_wire.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> Jason.decode!()

  # A vector's answer bytes, for the stub's host in place of `cyfr.run`.
  defp rehosted(name) do
    %{"bytes" => bytes} = Enum.find(@vectors["answers"], &(&1["name"] == name))

    String.replace(bytes, ~s("registry":"cyfr.run"), ~s("registry":"#{RegistryStub.host()}"))
  end

  test "an answer names the identifier and its directory" do
    RegistryStub.start!(fn _ -> {200, rehosted("an answer")} end)

    assert {:ok, %HandleAnswer{} = answer} = Handle.resolve("alice")
    assert answer.handle == "alice"
    assert answer.registry == RegistryStub.host()
    assert answer.directory == "https://cyfr.run"
    assert "per_" <> _ = answer.identifier

    assert_received {:registry_request, %{method: "GET", path: "/v1/handles/alice", body: ""}}
  end

  test "an answer for another handle or registry, carrying an address, or outside its grammar, is malformed" do
    for name <- [
          "an answer for another handle",
          "an answer carrying an address",
          "an unknown key",
          "no identifier",
          "not JSON"
        ] do
      bytes = rehosted(name)
      RegistryStub.start!(fn _ -> {200, bytes} end)
      assert {:error, :malformed_answer} = Handle.resolve("alice"), name
    end

    # The vector's own host is not the one asked here.
    %{"bytes" => foreign} =
      Enum.find(@vectors["answers"], &(&1["name"] == "an answer"))

    RegistryStub.start!(fn _ -> {200, foreign} end)
    assert {:error, :malformed_answer} = Handle.resolve("alice")
  end

  test "a handle no one holds is not found, its envelope or a bare 404" do
    RegistryStub.start!(fn _ -> RegistryStub.refusal(:handle_not_found) end)
    assert {:error, :not_found} = Handle.resolve("alice")

    RegistryStub.start!(fn _ -> {404, ""} end)
    assert {:error, :not_found} = Handle.resolve("alice")
  end

  test "a registry that refuses, fails or cannot be reached is unavailable" do
    capture_log(fn ->
      RegistryStub.start!(fn _ -> RegistryStub.refusal(:rate_limited) end)
      assert {:error, :registry_unavailable} = Handle.resolve("alice")

      RegistryStub.start!(fn _ -> {503, "Bad Gateway"} end)
      assert {:error, :registry_unavailable} = Handle.resolve("alice")

      RegistryStub.start!(fn _ -> :close end)
      assert {:error, :registry_unavailable} = Handle.resolve("alice")

      RegistryStub.start!(fn _ -> {302, ""} end)
      assert {:error, :registry_unavailable} = Handle.resolve("alice")
    end)
  end

  test "a spelling the slug grammar refuses, and no registry, ask nothing" do
    RegistryStub.start!(fn _ -> flunk("no request is sent") end)

    for handle <- ["Alice", "a/b", "", "-alice", String.duplicate("a", 40)] do
      assert {:error, :invalid_handle} = Handle.resolve(handle)
    end

    assert {:error, :invalid_handle} = Handle.resolve(nil)

    Application.put_env(:sanctum, :registry_url, "none")
    assert {:error, :no_registry} = Handle.resolve("alice")

    refute_received {:registry_request, _}
  end
end
