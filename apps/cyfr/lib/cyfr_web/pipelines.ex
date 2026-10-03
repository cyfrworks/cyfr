# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Pipelines do
  @moduledoc """
  The pipelines more than one route provider uses, defined once as data.

  `browser_plugs/1` is the browser pipeline's plugs in order;
  `browser/2` declares a pipeline from it where the composition router
  expands it. `oauth_callback_throttle_plugs/0` is the throttle an OAuth
  callback passes, and `oauth_callback_throttle/0` declares it. The route
  map's source reader reads the same data, so a pipeline and what the map
  records of it cannot drift apart.
  """

  @doc """
  The browser pipeline's plugs in order, each as `{plug, options}`.

  A headless node is refused first, and a request a frame made before
  the session is fetched. `:put_root_layout` is present only
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
      # Before the session: a frame's request reaches none (`FrameRequest`).
      {CyfrWeb.Plugs.FrameRequest, []},
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

  @doc """
  The OAuth callback throttle's plugs, each as `{plug, options}`.

  Callbacks arrive from identity providers on real people's behalf,
  often through shared-NAT corporate addresses, so the budget is generous:
  high enough that a floor of real people never trips it, low enough that
  one address cannot spin the token exchange unboundedly. The vault's
  OAuth grant callback and the browser's sign-in callbacks pass it, and
  share its one per-address bucket.
  """
  @spec oauth_callback_throttle_plugs() :: [{module(), keyword()}]
  def oauth_callback_throttle_plugs do
    [
      {CyfrWeb.Plugs.AuthRateLimit,
       [bucket: :oauth_callback, max_requests: 60, window_ms: 60_000]}
    ]
  end

  @doc """
  Declares the `:oauth_callback_throttle` pipeline from
  `oauth_callback_throttle_plugs/0`.

  Every provider whose routes pass it expands this, and every provider
  expands into the one composition router, so the pipeline is declared
  by the first expansion and every later one declares nothing: a router
  holds one definition of a pipeline name. The first expansion marks the
  definition as its own, and a pipeline of that name the router declared
  any other way refuses the compile, so a hand-written copy with another
  budget can never stand in for this one.
  """
  defmacro oauth_callback_throttle do
    plugs =
      for {plug, plug_opts} <- oauth_callback_throttle_plugs() do
        quote do: plug(unquote(plug), unquote(Macro.escape(plug_opts)))
      end

    quote do
      cond do
        Module.has_attribute?(__MODULE__, :cyfr_shared_oauth_callback_throttle) ->
          :ok

        Module.defines?(__MODULE__, {:oauth_callback_throttle, 2}) ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} declares the :oauth_callback_throttle pipeline " <>
                  "itself; it is CyfrWeb.Pipelines.oauth_callback_throttle/0's alone"

        true ->
          Module.register_attribute(__MODULE__, :cyfr_shared_oauth_callback_throttle, [])
          Module.put_attribute(__MODULE__, :cyfr_shared_oauth_callback_throttle, true)

          pipeline :oauth_callback_throttle do
            (unquote_splicing(plugs))
          end
      end
    end
  end
end
