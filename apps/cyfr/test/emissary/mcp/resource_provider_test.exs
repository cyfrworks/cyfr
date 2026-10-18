# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceProviderTest do
  @moduledoc """
  A resource is advertised by an operation provider
  (`c:Prima.Provider.resources/0`, `c:Prima.Provider.resource_templates/0`)
  and read through the one operation that declares its scheme. There is no
  separate resource behaviour and no read callback: every provider that
  advertises a resource is read through the gate.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Catalog
  alias Prima.{Arg, Operation, Provider}

  defmodule Advertiser do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "advertiser"

    @impl true
    def tools do
      [
        Operation.tool([
          Operation.new(
            "advertiser",
            "read_resource",
            "Read an adv:// resource",
            [Arg.new("uri", :string, required: true)],
            kind: :read,
            planes: [:external],
            recovery: :replay_safe,
            resource_schemes: ["adv"]
          )
        ])
      ]
    end

    @impl true
    def resources, do: [%{uri: "adv://one", name: "One"}]

    @impl true
    def resource_templates, do: [%{uriTemplate: "adv://items/{id}", name: "Item"}]

    @impl true
    def handle("advertiser", _ctx, %{"uri" => uri}), do: {:ok, %{content: uri}}
  end

  test "resources and templates are optional provider callbacks; there is no read callback" do
    callbacks = Provider.behaviour_info(:callbacks)
    optional = Provider.behaviour_info(:optional_callbacks)

    for callback <- [resources: 0, resource_templates: 0, context_kind: 0] do
      assert callback in callbacks
      assert callback in optional
    end

    refute {:read, 2} in callbacks
    refute Code.ensure_loaded?(Emissary.MCP.ResourceProvider)
  end

  test "an advertised scheme names its declared reader" do
    assert Provider.resource_scheme("adv://items/{id}") == {:ok, "adv"}
    assert Provider.resource_scheme("no-scheme") == :error
    assert Provider.resource_scheme("://x") == :error
    assert Provider.resource_scheme(nil) == :error
    assert :ok = Catalog.audit_resource_schemes([Advertiser])
  end

  test "every configured provider that advertises a resource declares its reader" do
    providers = Catalog.configured_providers()
    Enum.each(providers, &Code.ensure_loaded!/1)

    advertisers =
      for module <- providers,
          fun <- [:resources, :resource_templates],
          function_exported?(module, fun, 0),
          apply(module, fun, []) != [],
          uniq: true,
          do: module

    assert Enum.sort(advertisers) ==
             Enum.sort([
               Compendium.Provider,
               Opus.Provider,
               Sanctum.Providers.System,
               Sanctum.Provider
             ])

    # No configured provider, an advertiser or not, keeps a read/2 the
    # gate never calls: a resource is read through its declared operation.
    for module <- providers do
      refute function_exported?(module, :read, 2),
             "#{inspect(module)} exports a read/2 beside the declared readers"
    end

    assert :ok = Catalog.audit_resource_schemes()
  end
end
