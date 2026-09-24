# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Components do
  @moduledoc """
  The component facts a consent decision rests on.

  A consent governs the shape of what a component may do, so deciding one
  means reading what the estate actually holds: the activation a ref
  resolves to, the verified graph and its digest, the registry row a ref
  names, the estate's enabled agents, and what the install media ships at
  a row's path. None of that is identity's to know, and all of it
  lives in the component domain — so the contract is written here, in the
  domain that depends on it, and the component domain implements it
  (`Compendium.ConsentFacts`).

  The *shapes* consent and components agree on are not here: a manifest's
  `needs` and `caps` blocks, a component path, an activation node key, the
  ordering that picks a name's newest row and an agent ref are data both
  sides read from
  `Prima.Manifest.Needs`, `Prima.Manifest.Caps`, `Prima.ComponentPath`,
  `Prima.ComponentRow` and `Prima.AgentRef`. Carrying them through a
  callback would be an indirection around data that changes nothing.
  What is here takes a context and reads state.

  The implementation is written at boot: `Cyfr.Application` installs it
  with `install!/1`, and `impl!/0` reads it.

  ## Unavailable is not absent, and neither is denied

  Every call answers `{:error, :component_facts_unavailable}` when no
  implementation is installed, which is a different word from
  `{:error, :not_found}` (the estate holds no such component) and from
  every refusal `Sanctum.Consent.Authz` renders (the consent does not
  cover it). A decision taken while the facts cannot be read refuses, and
  the caller can tell which of the three happened — an unreadable estate
  must never read as a component that does not exist, and neither must
  read as a denial. `impl!/0`, which a caller asks only when it needs
  the module itself, raises `Sanctum.Consent.Components.NotInstalledError`
  instead.
  """

  alias Sanctum.Context

  defmodule NotInstalledError do
    @moduledoc """
    Raised by `Sanctum.Consent.Components.impl!/0` when nothing has
    installed the component-facts port.
    """

    defexception message:
                   "Sanctum.Consent.Components has no installed implementation: nothing " <>
                     "called Sanctum.Consent.Components.install!/1. The component facts a " <>
                     "consent rests on cannot be read until boot installs one."
  end

  # The port's own term, written once at boot.
  @key {__MODULE__, :impl}

  @typedoc "The activation of a component and its static closure."
  @type activation :: %{digest: String.t(), graph: %{String.t() => String.t()}}

  @typedoc "An activation with each node's stored release digest verified."
  @type verified :: %{
          digest: String.t(),
          graph: %{String.t() => String.t()},
          nodes: %{String.t() => %{release_digest: String.t(), integrity: :ok | :mismatch}}
        }

  @doc "The activation a component row's static closure resolves to."
  @callback resolve(Context.t(), map()) :: {:ok, activation()} | {:error, term()}

  @doc """
  The activation, with each node's stored release digest recomputed from
  its own inputs — the check that says a row was altered outside the
  publish path rather than released anew.
  """
  @callback resolve_verified(Context.t(), map()) :: {:ok, verified()} | {:error, term()}

  @doc """
  The registry row a ref names: the exact version when `version` is one,
  the newest published otherwise. One callback rather than two because a
  pinned ref and a versionless one are the same question asked of the
  same table, and a caller that checked only the newest would admit a
  pinned ref whose own version is gone.
  """
  @callback get_component(
              Context.t(),
              String.t(),
              String.t() | nil,
              String.t() | nil,
              String.t() | nil
            ) :: {:ok, map()} | {:error, term()}

  @doc "The row of every enabled agent in the estate's tree, the soul first."
  @callback agent_rows(Context.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  What the install media ships for each of `rows`, as a map from node key
  to the release digest the *seed* holds — never the athanor's copy. A
  row the seed does not ship, or ships edited, is absent from the map.

  One callback rather than three because the answer is one fact — "did
  the operator vouch for this, unchanged?" — and its three cases (an
  agent file, a tincture's directory, a WASM unit) are the component
  domain's own layout, which consent must not learn.
  """
  @callback shipped_nodes(Context.t(), [map()]) :: {:ok, %{String.t() => String.t()}}

  @doc """
  Install the port's implementation. Called once by `Cyfr.Application` at
  boot, before any consent is decided.

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
            "#{inspect(module)} does not implement Sanctum.Consent.Components: missing " <>
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
  The installed implementation. Raises
  `Sanctum.Consent.Components.NotInstalledError` when there is none; the
  calls below answer `{:error, :component_facts_unavailable}` instead.
  """
  @spec impl!() :: module()
  def impl! do
    case installed() do
      nil -> raise NotInstalledError
      module -> module
    end
  end

  @doc "The activation a component row's static closure resolves to."
  @spec resolve(Context.t(), map()) :: {:ok, activation()} | {:error, term()}
  def resolve(%Context{} = ctx, component) when is_map(component),
    do: call(& &1.resolve(ctx, component))

  @doc "The verified activation of a component row's static closure."
  @spec resolve_verified(Context.t(), map()) :: {:ok, verified()} | {:error, term()}
  def resolve_verified(%Context{} = ctx, component) when is_map(component),
    do: call(& &1.resolve_verified(ctx, component))

  @doc "The newest registry row for a name, publisher and type."
  @spec get_latest(Context.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def get_latest(%Context{} = ctx, name, publisher \\ nil, type \\ nil) when is_binary(name),
    do: get_component(ctx, name, nil, publisher, type)

  @doc """
  The registry row a ref names — the exact version when it carries one,
  the newest published otherwise.
  """
  @spec get_component(
          Context.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, map()} | {:error, term()}
  def get_component(%Context{} = ctx, name, version, publisher, type) when is_binary(name),
    do: call(& &1.get_component(ctx, name, version, publisher, type))

  @doc "The row of every enabled agent in the estate's tree."
  @spec agent_rows(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def agent_rows(%Context{} = ctx), do: call(& &1.agent_rows(ctx))

  @doc "The release digest the install media ships for each of `rows`, by node key."
  @spec shipped_nodes(Context.t(), [map()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def shipped_nodes(%Context{} = ctx, rows) when is_list(rows),
    do: call(& &1.shipped_nodes(ctx, rows))

  # An uninstalled port is an unreadable estate, not an empty one: every
  # caller refuses on this word, and none of them may mistake it for
  # `:not_found`.
  defp call(fun) do
    case installed() do
      nil -> {:error, :component_facts_unavailable}
      module -> fun.(module)
    end
  end

  defp installed, do: :persistent_term.get(@key, nil)
end
