# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.ProxyTest.Stub do
  @moduledoc false
  # A proxy that answers from the name alone, so a case can see that the
  # table asked the installed port and nothing else.
  @behaviour Grimoire.Proxy

  @impl true
  def server_tools(_ctx, name), do: {:ok, [%{"name" => "#{name}-tool"}]}

  @impl true
  def try_handle("stub:" <> tool, _ctx, _args, plane, _opts),
    do: {:ok, %{"answered_by" => "stub", "tool" => tool, "plane" => Atom.to_string(plane)}}

  def try_handle(_name, _ctx, _args, _plane, _opts), do: {:error, :not_external}

  @impl true
  def consent_candidates(_ctx),
    do: [%{name: "stub", server_digest: nil, tool_patterns: ["*"]}]

  @impl true
  def consent_candidate(_ctx, "stub"), do: {:ok, hd(consent_candidates(nil))}
  def consent_candidate(_ctx, _name), do: {:error, :not_found}

  @impl true
  def list_external_tools(_ctx),
    do: [%{"name" => "stub:echo", "description" => "stub", "inputSchema" => %{}}]
end

defmodule Grimoire.ProxyTest.Partial do
  @moduledoc false
  def list_external_tools(_ctx), do: []
end

defmodule Grimoire.ProxyTest do
  @moduledoc """
  The proxied-tool port: declared by the gate, implemented by the
  transport, written once at boot, and the only way the operation table
  reaches the tools an athanor's external servers define.

  The port owns a `:persistent_term`, so these cases are synchronous and
  put back the implementation the boot installed.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Proxy
  alias Grimoire.ProxyTest.{Partial, Stub}

  setup do
    installed = Proxy.impl!()
    on_exit(fn -> Proxy.install!(installed) end)
    :ok
  end

  test "the one implementation is the transport's external half, and it declares the port" do
    assert Proxy.impl!() == Emissary.External.Proxy

    behaviours =
      Emissary.External.Proxy.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Grimoire.Proxy in behaviours
  end

  test "every proxied tool is in-chain by default" do
    assert Proxy.default_planes() == [:in_chain]
  end

  test "an uninstalled port raises where it is asked" do
    Proxy.reset()

    error = assert_raise Proxy.NotInstalledError, fn -> Proxy.impl!() end
    assert error.message =~ "Grimoire.Proxy.install!/1"
  end

  test "an install that does not answer every callback is refused, and changes nothing" do
    for module <- [Partial, Grimoire.ProxyTest.NoSuchModule] do
      assert_raise ArgumentError, ~r/does not implement Grimoire.Proxy: missing/, fn ->
        Proxy.install!(module)
      end
    end

    assert Proxy.impl!() == Emissary.External.Proxy
  end

  describe "the operation table asks the installed port" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      Proxy.install!(Stub)
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "a proxied name is dispatched to it, from the caller's plane", %{ctx: ctx} do
      assert {:ok, %{"answered_by" => "stub", "tool" => "echo", "plane" => "external"}} =
               Grimoire.Catalog.call_external("stub:echo", ctx, %{})
    end

    test "a name the port does not know is an unknown tool", %{ctx: ctx} do
      assert {:error, "Unknown tool: other:echo"} =
               Grimoire.Catalog.call_external("other:echo", ctx, %{})
    end

    test "consent's view of the tool servers is the port's", %{ctx: ctx} do
      assert [%{name: "stub"}] = Grimoire.Catalog.tool_server_candidates(ctx)
      assert {:ok, %{name: "stub"}} = Grimoire.Catalog.tool_server_candidate(ctx, "stub")
      assert {:error, :not_found} = Grimoire.Catalog.tool_server_candidate(ctx, "gone")
    end

    test "the tool listing carries the port's proxied tools", %{ctx: ctx} do
      assert {:ok, %{tools: tools}} =
               Grimoire.Provider.handle("tools", ctx, %{"action" => "list"})

      assert Enum.any?(tools, &(&1["name"] == "stub:echo"))
    end
  end
end
