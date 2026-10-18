# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Components do
  @moduledoc """
  The component facts a consent decision rests on, and the filling of an
  athanor with its components.

  A consent governs the shape of what a component may do, so deciding one
  means reading what the athanor actually holds: the activation a ref
  resolves to, the verified graph and its digest, the registry row a ref
  names, the athanor's enabled agents, what the install media ships at
  a row's path, the newer version it ships of a row's component, and the
  placement a tincture's declaration names under the frame's rules. None of that is identity's to know, and all of it
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
  What is here takes a context and reads state, except `fill/3`.

  ## Filling an athanor

  An athanor holds no components until the component domain fills it:
  the seed bundle copied in and registered, the published closure pulled,
  the agents indexed. Identity owns the athanor's claim, the baseline
  consents the fill mints and the readiness written on the row
  (`Sanctum.Provisioning`), and asks for the fill through `fill/3`, the
  one upward call this port carries that writes. The implementation calls
  back down into `Sanctum.Provisioning` for the claim and the consents, so
  `fill/3` is asked with no transaction open and no lock held.

  The implementation is written at boot: `Cyfr.Application` installs it
  with `install!/1`, and `impl!/0` reads it.

  ## Unavailable is not absent, and neither is denied

  Every call answers `{:error, :component_facts_unavailable}` when no
  implementation is installed, which is a different word from
  `{:error, :not_found}` (the athanor holds no such component) and from
  every refusal `Sanctum.Consent.Authz` renders (the consent does not
  cover it). A decision taken while the facts cannot be read refuses, and
  the caller can tell which of the three happened — an unreadable athanor
  must never read as a component that does not exist, and neither must
  read as a denial. `impl!/0`, which a caller asks only when it needs
  the module itself, raises `Sanctum.Consent.Components.NotInstalledError`
  instead, and so does `fill/3`: an athanor nothing can fill is a boot
  that wired no port, not an athanor that failed.
  """

  alias Sanctum.Context

  @doc "Whether a component-facts read could not answer, distinct from absence or damage."
  defguard is_outage(reason)
           when reason in [
                  :database_error,
                  :unavailable,
                  :projection_unavailable,
                  :component_facts_unavailable
                ]

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

  @doc "The row of every enabled agent in the athanor's tree, the soul first."
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
  The newest version the install media ships of `row`'s component, when
  it is strictly newer than the row's own; nil when the media ships none
  newer, or none at all. What a consent offers as the update when a
  component's need is one an older version reads itself.
  """
  @callback newer_shipped(Context.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc """
  The placement a tincture row's declaration names under the frame's
  rules as they are today: `{:ok, placement}`, nil for a tincture that
  names none, or `{:error, :refused}` when those rules refuse the
  declaration. The rules are the component domain's, so consent asks
  for this verdict rather than reading a placement from the raw manifest.

  Optional: an implementation that does not answer it is asked nothing,
  and the port answers `{:error, :component_facts_unavailable}` for it.
  """
  @callback tincture_placement(Context.t(), map()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Fill `athanor` with its components, acting as `acting_ctx` (the
  person's context focused on the athanor, whose pull credential is used;
  nil fills as the server).

  `entry_kind` names who asked, as the athanor's claim records it.
  `"provision"` is the explicit verb: the attempt runs in the caller's
  process and the answer is the attempt's own — `{:ok, athanor}` filled,
  `{:error, :provisioning_busy}` while another attempt holds the athanor,
  `{:error, {:provisioning_failed, step, detail}}` with the failure on the
  row. Every other kind is a hook no request path may wait on: the attempt
  is started in the background and `:ok` answers at once.
  """
  @callback fill(map(), Context.t() | nil, String.t()) ::
              :ok | {:ok, map()} | {:error, term()}

  @optional_callbacks tincture_placement: 2

  @doc """
  Install the port's implementation. Called once by `Cyfr.Application` at
  boot, before any consent is decided.

  A module that does not export every required callback is refused here,
  loudly, at boot, and the port is left as it was. An optional callback it
  does not export is answered as unavailable when asked.
  """
  @spec install!(module()) :: module()
  def install!(module) when is_atom(module) do
    required =
      __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks)

    missing =
      for {name, arity} <- required,
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

  @doc "The row of every enabled agent in the athanor's tree."
  @spec agent_rows(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def agent_rows(%Context{} = ctx), do: call(& &1.agent_rows(ctx))

  @doc "The release digest the install media ships for each of `rows`, by node key."
  @spec shipped_nodes(Context.t(), [map()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def shipped_nodes(%Context{} = ctx, rows) when is_list(rows),
    do: call(& &1.shipped_nodes(ctx, rows))

  @doc "The newest shipped version of `row`'s component when newer than its own, else nil."
  @spec newer_shipped(Context.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def newer_shipped(%Context{} = ctx, row) when is_map(row),
    do: call(& &1.newer_shipped(ctx, row))

  @doc """
  The placement a tincture row's declaration names under today's rules,
  or `{:error, :refused}` when they refuse it.
  `{:error, :component_facts_unavailable}` when no implementation is
  installed, or the installed one does not answer this optional callback:
  a placement that cannot be asked is never read as one that was answered.
  """
  @spec tincture_placement(Context.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def tincture_placement(%Context{} = ctx, row) when is_map(row) do
    call(fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :tincture_placement, 2),
        do: module.tincture_placement(ctx, row),
        else: {:error, :component_facts_unavailable}
    end)
  end

  @doc """
  Fill `athanor`, as `c:fill/3` describes. Raises
  `Sanctum.Consent.Components.NotInstalledError` when no implementation is
  installed.
  """
  @spec fill(map(), Context.t() | nil, String.t()) :: :ok | {:ok, map()} | {:error, term()}
  def fill(%{id: athanor_id} = athanor, acting_ctx, entry_kind)
      when is_binary(athanor_id) and (is_nil(acting_ctx) or is_struct(acting_ctx, Context)) and
             is_binary(entry_kind),
      do: impl!().fill(athanor, acting_ctx, entry_kind)

  # An uninstalled port is an unreadable athanor, not an empty one: every
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
