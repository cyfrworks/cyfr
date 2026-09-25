# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Providers.Tincture do
  @moduledoc """
  The `tincture` tool: a tincture invoking one of its dependencies, as two
  declared operations.

  - `invoke_public` roots the run at the tincture's published public
    profile and serves any caller, a public tincture being public by
    definition.
  - `invoke_protected` roots it at the tincture's owner profile and serves
    an authenticated caller under Sanctum's private-access policy.

  The action fixes the route; nothing in the arguments selects a tenant, a
  profile or a route. `invoke_public` names the tincture by its public
  address as its URL does — the athanor segment, which confers no
  authority — and `invoke_protected` works in the caller's own athanor. Every surface — the HTTP tincture endpoint, the
  console shell's iframe bridge and `/mcp` — reaches the invocation through
  the gate, which authorizes, casts and logs the call once;
  `Crucible.invoke_tincture/3` does the rest. Neither action is reachable
  from a running chain.
  """

  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @routes %{"invoke_public" => :public, "invoke_protected" => :protected}

  @impl true
  def service, do: "crucible"

  @impl true
  def resources, do: []

  @impl true
  def resource_templates, do: []

  @impl true
  def tools do
    [
      Operation.tool(
        [
          invoke("invoke_public", "Invoke a public tincture's dependency", [address()],
            auth: :anonymous
          ),
          invoke("invoke_protected", "Invoke a tincture's dependency", [], auth: :required)
        ],
        description:
          "Invoke a component a tincture declares among its dependencies, under the " <>
            "tincture's public profile (invoke_public) or its owner profile (invoke_protected)"
      )
    ]
  end

  # A public tincture is addressed as its URL addresses it: the athanor's
  # public segment. The address confers no authority — the tincture's
  # active public profile admits the call — so it selects no tenant for
  # the caller; the protected action has none and works in the caller's
  # own athanor.
  defp address do
    Arg.new("athanor", :string,
      required: true,
      description:
        "The tincture's public address: its athanor's URL segment " <>
          "('@<namespace>' for a person's, the slug for a group's)"
    )
  end

  defp invoke(action, description, address, auth) do
    Operation.new(
      "tincture",
      action,
      description,
      address ++
        [
          Arg.new("publisher", :string,
            required: true,
            description: "The tincture's publisher (e.g. 'local')"
          ),
          Arg.new("tincture_name", :string, required: true, description: "The tincture's name"),
          Arg.new("reference", :string,
            required: true,
            description: "The dependency to invoke, as the tincture's manifest declares it"
          ),
          Arg.new("input", {:map, Arg.new(nil, :json)},
            required: true,
            description: "The input to pass to the dependency"
          )
        ],
      [
        kind: :execute,
        planes: [:external],
        consent: nil,
        standing: false,
        recovery: nil,
        permission: nil
      ] ++ auth
    )
  end

  @impl true
  def handle("tincture", %Context{} = ctx, %{"action" => action} = args)
      when is_map_key(@routes, action) do
    Crucible.invoke_tincture(ctx, args, Map.fetch!(@routes, action))
  end

  def handle("tincture", _ctx, _args),
    do:
      {:error, {:invalid_argument, Prima.Provider.invalid_action("tincture", Map.keys(@routes))}}
end
