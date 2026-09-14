# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderToolchainsTest do
  @moduledoc """
  With a builder container configured, `build.toolchains` answers what the
  container reports, not what this node has installed; a builder that
  cannot be reached is unavailable.
  """

  use ExUnit.Case, async: false

  alias Locus.MCP

  setup do
    previous = Application.get_env(:cyfr, :builder_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cyfr, :builder_url, previous),
        else: Application.delete_env(:cyfr, :builder_url)
    end)

    :ok
  end

  defp serve_health(body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    json = Jason.encode!(body)

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      _ = :gen_tcp.recv(sock, 0, 1_000)

      :ok =
        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n" <> json
        )

      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end

  test "the configured builder's toolchains are the answer" do
    url =
      serve_health(%{
        "ok" => true,
        "toolchains" => %{
          "rust" => %{
            "available" => true,
            "command" => "cargo-component",
            "description" => "Rust"
          }
        }
      })

    Application.put_env(:cyfr, :builder_url, url)

    assert {:ok, %{toolchains: toolchains}} =
             MCP.handle("build", Sanctum.TestContext.local(), %{"action" => "toolchains"})

    assert toolchains.rust == %{available: true, command: "cargo-component", description: "Rust"}
    assert toolchains.javascript.available == false
  end

  test "a builder that cannot be reached is unavailable" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    Application.put_env(:cyfr, :builder_url, "http://127.0.0.1:#{port}")

    assert {:error, {:unavailable, _}} =
             MCP.handle("build", Sanctum.TestContext.local(), %{"action" => "toolchains"})
  end
end
