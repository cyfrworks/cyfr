# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Proxy do
  @moduledoc """
  The operation table's view of the tools an athanor's external MCP
  servers define: resolving a proxied `server:tool` name, dispatching a
  call to it, and describing each server for a consent grant.

  The table cannot declare those tools. An upstream catalogue is
  unbounded and changes without us, so a lookup miss on a namespaced
  name asks this port, and the transport that speaks to the servers
  answers it. The contract is written here, in the gate that depends on
  it; the one implementation is `Emissary.External.Proxy`, and
  `Cyfr.Application` writes it in at boot with `install!/1`. Nothing in
  the gate names the transport.

  ## Two questions

  A proxied call is admitted before it runs, like any other. The gate
  asks `c:resolve/4` first — is there such a tool the caller may reach
  from its plane — and records its decision on the answer; only an
  admitted call is then run through `c:dispatch/5`, with the target
  `c:resolve/4` answered. The target is the implementation's own and the
  gate never looks inside it.

  ## Refusals

  `c:resolve/4` answers `{:error, :not_external}` for a name that is
  not an external tool — no `server:` prefix, or no server of that name
  in the caller's athanor — and the table then answers the name as
  unknown. Every other refusal either callback makes is a reason
  `Grimoire.Error.classify/1` knows, or a `%Prima.Refusal{}` already
  built, never a bare sentence: `c:resolve/4`'s are the admission's,
  `c:dispatch/5`'s the call's.

  ## Fail closed

  `impl!/0` raises `Grimoire.Proxy.NotInstalledError` when nothing has
  been installed: a table that cannot ask about proxied tools must not
  read every `server:tool` name as unknown.
  """

  alias Sanctum.Context

  defmodule NotInstalledError do
    @moduledoc """
    Raised by `Grimoire.Proxy.impl!/0` when nothing has installed the
    proxied-tool port.
    """

    defexception message:
                   "Grimoire.Proxy has no installed implementation: nothing called " <>
                     "Grimoire.Proxy.install!/1. Proxied tools cannot be resolved until " <>
                     "boot installs one."
  end

  # The port's own term, written once at boot and read on every proxied
  # lookup.
  @key {__MODULE__, :impl}

  @typedoc "The plane a proxied call is made from."
  @type plane :: :in_chain | :external

  @typedoc """
  Why a proxied call was refused: `:not_external` when the name is no
  external tool, otherwise a classified reason or a built refusal.
  """
  @type reason :: :not_external | Prima.Refusal.t() | term()

  @typedoc "What `c:resolve/4` resolved a name to: the implementation's own, opaque to the gate."
  @type target :: term()

  @doc """
  The tools one of the caller's athanor's servers answers with now, as
  its running process last listed them.
  """
  @callback server_tools(Context.t(), server_name :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Resolve `name` as a proxied `server:tool` a caller on `plane` may call:
  the server present in the caller's athanor and enabled, the tool one
  its patterns expose, and the plane one the server is reachable from.
  `opts[:server]` is the server row the caller already judged, which the
  target then names; without it the row is read once.
  """
  @callback resolve(name :: String.t(), Context.t(), plane(), opts :: keyword()) ::
              {:ok, target()} | {:error, reason()}

  @doc """
  Run the call `target` names from `plane`: the call an admitted
  `c:resolve/4` answer names. `opts` carries what an in-chain call is
  admitted under: `:execution_id`, `:step`, `:hold` and
  `:retention_class`.
  """
  @callback dispatch(target(), Context.t(), args :: map(), plane(), opts :: keyword()) ::
              {:ok, map()} | {:error, reason()}

  @doc "Every external tool server of the caller's athanor, each as a grant candidate."
  @callback consent_candidates(Context.t()) :: [Sanctum.Grimoire.tool_server_candidate()]

  @doc "One external tool server by name, as a grant candidate, or why not."
  @callback consent_candidate(Context.t(), server_name :: String.t()) ::
              {:ok, Sanctum.Grimoire.tool_server_candidate()} | {:error, term()}

  @doc "The proxied tools of the caller's athanor, named `server:tool`."
  @callback list_external_tools(Context.t()) :: [map()]

  @doc """
  The plane every proxied tool is reached from.

  An upstream catalogue carries no annotation, so the whole bucket takes
  one default: in-chain. `c:resolve/4` refuses an external-plane call
  unless the server's own configuration opts in.
  """
  @spec default_planes() :: [Prima.Provider.plane(), ...]
  def default_planes, do: [:in_chain]

  @doc """
  Install the port's implementation. Called once by `Cyfr.Application` at
  boot, before the operation table serves a call.

  A module that does not export every callback is refused here, loudly,
  at boot, and the port is left as it was.
  """
  @spec install!(module()) :: module()
  def install!(module) when is_atom(module) do
    missing =
      for {name, arity} <- __MODULE__.behaviour_info(:callbacks),
          not (Code.ensure_loaded?(module) and function_exported?(module, name, arity)),
          do: "#{name}/#{arity}"

    if missing != [] do
      raise ArgumentError,
            "#{inspect(module)} does not implement Grimoire.Proxy: missing " <>
              Enum.join(missing, ", ")
    end

    :persistent_term.put(@key, module)
    module
  end

  @doc """
  Erase the installed implementation, leaving the port as boot found it.
  The inverse of `install!/1`, for a test that installs one of its own.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The installed implementation. Raises `Grimoire.Proxy.NotInstalledError`
  when there is none.
  """
  @spec impl!() :: module()
  def impl! do
    case :persistent_term.get(@key, nil) do
      nil -> raise NotInstalledError
      module -> module
    end
  end
end
