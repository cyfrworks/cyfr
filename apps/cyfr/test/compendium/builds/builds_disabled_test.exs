# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.BuildsDisabledTest do
  @moduledoc """
  A server with no builds service builds nothing: without its URL or
  without its key every build is refused where every surface reaches it,
  before a row is written or a request made.
  """
  # The builds service is application configuration, so this module owns
  # it for the duration of its tests and hands the previous values back.
  use ExUnit.Case, async: false

  alias Compendium.Builds.Provider
  alias Cyfr.Test.ScriptedBuilder

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    # A builder is listening, so a request made in error would be seen.
    ScriptedBuilder.start!()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp unconfigured do
    [
      {"no URL", nil, ScriptedBuilder.key()},
      {"no key", ScriptedBuilder.url(), nil},
      {"neither", nil, nil}
    ]
  end

  test "builds are enabled exactly when the URL and a 32-byte key are both configured" do
    assert Cyfr.RuntimeConfig.builds_enabled?()
    assert Cyfr.RuntimeConfig.locus_builds_url() == ScriptedBuilder.url()
    assert Cyfr.RuntimeConfig.locus_builds_key() == ScriptedBuilder.key()

    for {what, url, key} <- unconfigured() ++ [{"a key of another size", "http://b", "short"}] do
      ScriptedBuilder.configure!(url, key)
      refute Cyfr.RuntimeConfig.builds_enabled?(), what
    end
  end

  test "compile is refused on the one handler every surface reaches, before any row or request",
       %{ctx: ctx} do
    for {what, url, key} <- unconfigured() do
      ScriptedBuilder.configure!(url, key)
      refute Cyfr.RuntimeConfig.builds_enabled?(), what

      for args <- [
            %{"action" => "compile", "reference" => "catalyst:local.never-built"},
            %{
              "action" => "compile",
              "reference" => "catalyst:local.never-built",
              "async" => true,
              "build_id" => "build_disabled"
            }
          ] do
        assert {:error, message} = Provider.handle("build", ctx, args)
        assert message =~ "builds are disabled on this server", what
        assert message =~ "CYFR_LOCUS_BUILDS_URL"
        assert message =~ "CYFR_LOCUS_BUILDS_KEY"
      end

      assert {:error, :not_found} = Cyfr.BuildRecords.get(ctx, "build_disabled")
    end

    assert ScriptedBuilder.requests() == []
    assert Task.Supervisor.children(Compendium.Builds.TaskSupervisor) == []
  end

  test "the read-only actions still answer: no toolchain is available, and bytes still validate",
       %{ctx: ctx} do
    for {what, url, key} <- unconfigured() do
      ScriptedBuilder.configure!(url, key)

      assert {:ok, %{toolchains: toolchains}} =
               Provider.handle("build", ctx, %{"action" => "toolchains"})

      assert Enum.sort(Map.keys(toolchains)) == Enum.sort(Cyfr.BuilderProtocol.languages()), what
      assert Enum.all?(toolchains, fn {_language, toolchain} -> toolchain.available == false end)
    end

    wasm = <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

    assert {:ok, %{valid: true}} =
             Provider.handle("build", ctx, %{
               "action" => "validate",
               "wasm_base64" => Base.encode64(wasm)
             })

    assert {:error, {:not_found, "Build", "build_none"}} =
             Provider.handle("build", ctx, %{"action" => "status", "build_id" => "build_none"})
  end
end
