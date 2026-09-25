# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Pipelines do
  @moduledoc """
  The page pipelines every route provider shares, defined once as data.

  `browser_plugs/1` is the browser pipeline's plugs in order;
  `browser/2` declares a pipeline from it where the composition router
  expands it. The route map's source reader reads the same data, so the
  pipeline and what the map records of it cannot drift apart.
  """

  @doc """
  The browser pipeline's plugs in order, each as `{plug, options}`.

  A headless node is refused first. `:put_root_layout` is present only
  when `opts[:root_layout]` names a layout: a page rendered through
  `CyfrWeb.MinimalPage` takes none.
  """
  @spec browser_plugs(keyword()) :: [{module() | atom(), keyword() | [String.t()]}]
  def browser_plugs(opts \\ []) do
    layout =
      case Keyword.fetch(opts, :root_layout) do
        {:ok, root_layout} -> [{:put_root_layout, [html: root_layout]}]
        :error -> []
      end

    [
      # First: a headless node serves none of this (CYFR_HEADLESS).
      {CyfrWeb.Plugs.Headless, []},
      {:accepts, ["html"]},
      {:fetch_session, []},
      {:fetch_live_flash, []}
    ] ++
      layout ++
      [
        {:protect_from_forgery, []},
        {:put_secure_browser_headers, []},
        {CyfrWeb.Plugs.BrowserCSP, []}
      ]
  end

  @doc """
  Declares the browser pipeline `name` from `browser_plugs/1`.

  Expands inside a router, against its `use Phoenix.Router` and imports.
  The options are read at compile time and must be literal.
  """
  defmacro browser(name, opts \\ []) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)

    plugs =
      for {plug, plug_opts} <- browser_plugs(opts) do
        quote do: plug(unquote(plug), unquote(Macro.escape(plug_opts)))
      end

    quote do
      pipeline unquote(name) do
        (unquote_splicing(plugs))
      end
    end
  end
end
