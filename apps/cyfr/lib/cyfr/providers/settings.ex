# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.Settings do
  @moduledoc """
  The `settings` tool: the platform settings, for the server's operators
  only (`scope: :platform` on every action). The console's card, the CLI
  and a headless node's remote shell are adapters over the same three
  actions of `Cyfr.Platform.Settings`.

  `list` shows every setting with its value, default, source (`deployment
  | operator | default`), whether a restart-scoped value is pending, the
  desired store revision and the revision each member last observed.
  `set` validates the value through the setting's own validator and
  writes it; `reset` removes the stored value so the default applies.
  Both carry the store revision the change was made against, as `list`
  answered it, and a write made since refuses the change. A key the
  deployment's environment pins cannot be changed here.
  """

  @behaviour Prima.Provider

  alias Cyfr.Platform.Settings
  alias Sanctum.Context

  @impl true
  def service, do: "cyfr"

  @impl true
  def tools do
    alias Prima.{Arg, Operation}

    key = Arg.new("key", :string, required: true, description: "The setting, as list names it")

    revision =
      Arg.new("revision", :integer,
        min: 0,
        description:
          "The store revision the change is made against, as list answered it; a write " <>
            "made since refuses the change. Absent, the current revision"
      )

    [
      Operation.tool(
        [
          Operation.new("settings", "list", "List platform settings", [],
            scope: :platform,
            kind: :read,
            planes: [:external]
          ),
          Operation.new(
            "settings",
            "set",
            "Set a platform setting",
            [
              key,
              Arg.new("value", :string,
                required: true,
                description: "The value, written as the setting's variable takes it"
              ),
              revision
            ],
            scope: :platform,
            kind: :write,
            planes: [:external]
          ),
          Operation.new("settings", "reset", "Reset a platform setting", [key, revision],
            scope: :platform,
            kind: :write,
            planes: [:external]
          )
        ],
        description:
          "The server's platform settings — platform admins only. A live change reaches new " <>
            "and refreshed work on every member within the settings cache's bound, not work " <>
            "in flight; a restart setting applies at each member's next start. A setting " <>
            "the deployment's environment pins is read-only here.",
        title: "Platform Settings"
      )
    ]
  end

  @impl true
  def handle("settings", %Context{}, %{"action" => "list"}) do
    case Settings.list() do
      {:ok, listing} -> {:ok, Map.put(listing, :count, length(listing.settings))}
      {:error, reason} -> refuse(reason, nil)
    end
  end

  def handle(
        "settings",
        %Context{} = ctx,
        %{"action" => "set", "key" => key, "value" => value} = args
      )
      when is_binary(key) do
    case Settings.set(ctx, key, value, revision(args)) do
      {:ok, written} -> {:ok, written}
      {:error, reason} -> refuse(reason, key)
    end
  end

  def handle("settings", %Context{} = ctx, %{"action" => "reset", "key" => key} = args)
      when is_binary(key) do
    case Settings.reset(ctx, key, revision(args)) do
      {:ok, written} -> {:ok, written}
      {:error, reason} -> refuse(reason, key)
    end
  end

  def handle("settings", _ctx, %{"action" => "set", "key" => _key}),
    do: {:error, {:invalid_argument, "Missing required argument: value"}}

  def handle("settings", _ctx, %{"action" => action}) when action in ["set", "reset"],
    do: {:error, {:invalid_argument, "Missing required argument: key"}}

  def handle("settings", _ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "settings.#{action}"}}

  def handle(tool, _ctx, _args), do: {:error, {:not_found, "Tool", tool}}

  defp revision(%{"revision" => revision}) when is_integer(revision), do: [revision: revision]
  defp revision(_args), do: []

  defp refuse(:unknown_key, key), do: {:error, {:not_found, "Setting", key}}

  defp refuse(:pinned, key) do
    {:error,
     {:conflict,
      "#{key} is set by the deployment's environment and cannot be changed here; " <>
        "change it where the deployment is configured"}}
  end

  defp refuse(:stale, _key) do
    {:error, {:conflict, "The settings changed since they were read — list them again and retry"}}
  end

  defp refuse({:invalid, key, form}, _key), do: {:error, {:invalid_argument, "#{key} #{form}"}}
  defp refuse(:unavailable, _key), do: {:error, {:unavailable, "The platform settings store"}}
end
