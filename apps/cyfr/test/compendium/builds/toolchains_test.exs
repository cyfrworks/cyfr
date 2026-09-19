# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.ToolchainsTest do
  @moduledoc """
  `build.toolchains` answers what the builds service reports, since this
  server runs no toolchain of its own; a builder of another protocol is
  named with both ends' versions, and one that cannot be reached is
  unavailable.
  """

  use ExUnit.Case, async: false

  alias Compendium.Builds.Provider
  alias Cyfr.BuilderProtocol
  alias Cyfr.Test.ScriptedBuilder

  setup do
    ScriptedBuilder.start!()
    :ok
  end

  defp toolchains,
    do: Provider.handle("build", Sanctum.TestContext.local(), %{"action" => "toolchains"})

  test "the configured builder's toolchains are the answer" do
    ScriptedBuilder.health(%{
      release: "9.9.9",
      toolchains: %{
        rust: %{available: true, command: "cargo-component", description: "Rust"},
        javascript: %{available: false, command: "npm", description: "JavaScript"}
      }
    })

    assert {:ok, %{toolchains: toolchains}} = toolchains()
    assert toolchains.rust == %{available: true, command: "cargo-component", description: "Rust"}
    assert toolchains.javascript.available == false
  end

  test "a builder at another protocol names both ends' versions and the remedy" do
    health = Jason.decode!(ScriptedBuilder.fixture()["lines"]["health"]["body"])
    {:ok, refusal} = BuilderProtocol.encode_refusal({:protocol_mismatch, 3, 1}, [])

    for {line, builder} <- [
          {Jason.encode!(%{health | "version" => 2}), 2},
          {refusal, 3}
        ] do
      ScriptedBuilder.health({:line, line})

      assert {:error, message} = toolchains()
      assert message =~ "the builder speaks builder protocol #{builder}"
      assert message =~ "this server speaks builder protocol #{BuilderProtocol.version()}"
      assert message =~ "same release"
    end
  end

  @tag :capture_log
  test "an answer that is not the protocol's is refused, not read as no toolchains" do
    ScriptedBuilder.health({:line, ~s({"ok":true,"toolchains":{}})})

    assert {:error, message} = toolchains()
    assert message =~ "not the builder protocol's"
  end

  @tag :capture_log
  test "a builder that cannot be reached is unavailable" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    ScriptedBuilder.configure!("http://127.0.0.1:#{port}", ScriptedBuilder.key())

    assert {:error, {:unavailable, "The builder service"}} = toolchains()
  end
end
