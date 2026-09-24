# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Grimoire do
  @moduledoc """
  The operation catalog as consent sees it.

  A consent shape may only name `tool.action` pairs this server can serve,
  so shape derivation asks the catalog which those are. A grant on an
  external tool server may only name a server the catalog proxies, so a
  plan and a commit ask it which servers those are and what each exposes.
  Both ask through this port rather than the catalog module directly: the
  contract is written here, in the domain that depends on it, and the one
  implementation answers for every provider it has loaded. A provider that
  cannot load is a boot failure there, never a narrower answer here — a
  digest derived from a partial catalog would read as the whole.

  Which module that is, `Cyfr.Application` writes at boot with
  `install!/1`, so nothing here names it: a default spelled in code would
  be a compile-time reference to the layer above. Before the boot write
  the catalog is unreadable, and every call raises
  `Sanctum.Grimoire.NotInstalledError` rather than answering a narrower
  roster — a shape derived from no catalog at all would grant nothing and
  read as a component that asks for nothing.
  """

  alias Sanctum.Context

  defmodule NotInstalledError do
    @moduledoc """
    Raised by `Sanctum.Grimoire.impl!/0` when nothing has installed the
    operation catalog's port. An uninstalled port is not an empty catalog:
    consent cannot say which actions exist, and refuses to guess.
    """

    defexception message:
                   "Sanctum.Grimoire has no installed implementation: nothing called " <>
                     "Sanctum.Grimoire.install!/1. Consent cannot read the operation " <>
                     "table until boot installs one."
  end

  # The port's own term, written once at boot and read on every consent
  # derivation.
  @key {__MODULE__, :impl}

  @typedoc """
  An external tool server as a grant may name it: its `name`, the
  `server_digest` a grant binds to (`nil` when its configuration cannot be
  digested), the `tool_patterns` the operator exposes and, when the server
  answered, the `tool_names` matched and a `descriptions_digest` over
  their descriptions.
  """
  @type tool_server_candidate :: %{
          required(:name) => String.t(),
          required(:server_digest) => String.t() | nil,
          required(:tool_patterns) => [String.t()],
          optional(atom()) => term()
        }

  @doc "Every `tool.action` the catalog serves, from its loaded providers."
  @callback tool_actions() :: [String.t()]

  @doc "Whether every configured provider loaded, or which did not."
  @callback providers_loaded() :: :ok | {:error, [module()]}

  @doc """
  The external tool servers of the caller's athanor, each as a candidate.
  A server that cannot be reached is still one, with no matched tool
  names: a grant is on its configured patterns, not on what it happens to
  expose at the moment.
  """
  @callback tool_server_candidates(Context.t()) :: [tool_server_candidate()]

  @doc "One external tool server by name, as a candidate, or why not."
  @callback tool_server_candidate(Context.t(), String.t()) ::
              {:ok, tool_server_candidate()} | {:error, term()}

  @doc """
  Install the port's implementation. Called once by `Cyfr.Application` at
  boot, before anything derives a consent shape.

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
            "#{inspect(module)} does not implement Sanctum.Grimoire: missing " <>
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
  The installed implementation. Raises `Sanctum.Grimoire.NotInstalledError`
  when there is none: see the note above on why an unreadable catalog is
  not an empty one.
  """
  @spec impl!() :: module()
  def impl! do
    case :persistent_term.get(@key, nil) do
      nil -> raise NotInstalledError
      module -> module
    end
  end

  @spec tool_actions() :: [String.t()]
  def tool_actions, do: impl!().tool_actions()

  @spec tool_server_candidates(Context.t()) :: [tool_server_candidate()]
  def tool_server_candidates(%Context{} = ctx), do: impl!().tool_server_candidates(ctx)

  @spec tool_server_candidate(Context.t(), String.t()) ::
          {:ok, tool_server_candidate()} | {:error, term()}
  def tool_server_candidate(%Context{} = ctx, name) when is_binary(name),
    do: impl!().tool_server_candidate(ctx, name)
end
