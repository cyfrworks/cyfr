# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Offered do
  @moduledoc """
  The tools a turn offers: the soul's `tools` list
  (`Compendium.AquaAgent`), which every crew member is offered too, made
  exact against the catalog and the person's browser setting. Each call
  of it is decided as it runs (`Aqua.Loop.Policy`).

  The set is a map from an exact key to `"offered"` or `"off"`. Every
  entry names one action (the list has no wildcard), so the list a
  person reads is the set: an action a catalogued tool does not have is
  dropped; `native_search`, an outside server's `server:tool` and a tool
  nobody catalogues pass through as written (the request offers no
  uncatalogued tool, and an outside one as its server lists it,
  `Aqua.Loop.Turn.tools/3`).

  ## The browser follows the person's setting

  The browser tool's own actions (`Sanctum.Catalog.follows_setting?/2`)
  are offered as the person's browser setting says (`Aqua.BrowserSetting`):
  named in the list, they are `"offered"` with it on and `"off"` with it
  off, so a call of one is refused in the browser's own words. The list
  says only whether the member has the browser at all.
  """

  @typedoc """
  The person's browser setting as `Aqua.BrowserSetting.allowed?/1` read it
  under the caller's context. Only `{:ok, true}` is on: a store that could
  not answer reads as off.
  """
  @type setting :: {:ok, boolean()} | {:error, :unavailable}

  @typedoc "An offered set: each exact key, offered or turned off by the browser setting."
  @type t :: %{String.t() => String.t()}

  @doc """
  The set `tools` offers under the person's browser `setting`. The only
  thing that should ever be handed to a turn — the soul's or a crew
  member's — as what it may call.
  """
  @spec resolve([String.t()], setting()) :: t()
  def resolve(tools, setting) when is_list(tools) do
    on? = setting == {:ok, true}

    tools
    |> expand()
    |> Map.new(fn key ->
      {key, if(follows_setting?(key) and not on?, do: "off", else: "offered")}
    end)
  end

  @doc "Whether `key` is offered and not turned off."
  @spec offered?(t(), String.t()) :: boolean()
  def offered?(offered, key) when is_map(offered), do: Map.get(offered, key) == "offered"

  # Each entry as its exact key: an action a catalogued tool does not
  # have dropped, anything else as written.
  defp expand(tools) do
    tools
    |> Enum.flat_map(fn key ->
      case String.split(key, ".", parts: 2) do
        [tool, action] ->
          if Aqua.Kinds.catalogued?(tool) and action not in Aqua.Kinds.actions_of(tool),
            do: [],
            else: [key]

        _bare ->
          [key]
      end
    end)
    |> Enum.uniq()
  end

  defp follows_setting?(key) do
    case String.split(key, ".", parts: 2) do
      [tool, action] -> Sanctum.Catalog.follows_setting?(tool, action)
      _ -> false
    end
  end
end
