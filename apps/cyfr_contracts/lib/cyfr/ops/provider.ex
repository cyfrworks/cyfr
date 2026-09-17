# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Provider do
  @moduledoc """
  Behaviour for built-in operation providers.

  Providers declare actions with `Cyfr.Ops.Operation` and return tools
  materialized by `Cyfr.Ops.Operation.tool/2`. Arguments, discovery schemas
  and access/effect annotations derive from those declarations. The host
  catalog performs contextual authorization before invoking `handle/3`.

  The context is opaque at this shared boundary. Concrete providers must
  require their authenticated domain context; worker actor projections do
  not substitute for it. This behaviour contains no running catalog or
  infrastructure dependency.

  Handlers return `{:ok, result}` or `{:error, reason}`. List results use a
  plural resource key with optional count or pagination metadata; single
  reads return the record, and mutations return their resulting state.
  """

  @type icon :: %{
          required(:src) => String.t(),
          required(:mimeType) => String.t(),
          optional(:sizes) => [String.t()]
        }

  @type action_kind :: :read | :write | :execute | :destructive | :external

  @typedoc """
  Which authorization plane an action can be reached from.

  `:external` — reachable from an external ingress: an HTTP MCP call, the
  console, the CLI. Authorized by caller identity plus tenant policy.

  `:in_chain` — reachable from inside a running component. Authorized by the
  current authority's granted resources *and* the caller's identity, never
  by identity alone.

  Three things in this codebase are called a plane and none of them are the
  same: this axis, the `action_kind` value `:external` ("this action talks
  to the outside world"), and `Sanctum.Context`'s `plane` field
  (`:external | :guest`, tracking whether a context has entered a WASM
  closure). Read the qualifier, not the word.
  """
  @type plane :: :external | :in_chain

  @typedoc """
  Per-action access declaration — the gate, not a hint.

  `Cyfr.Ops.Catalog.do_call/4` enforces these keys at dispatch and
  `Cyfr.Ops.Visibility` derives discovery from the same map, so what
  a caller is shown and what a caller may invoke cannot drift apart.

  - `:auth` — `:anonymous` serves uncredentialed callers (device flow,
    health); `:signed_in` serves anyone holding a live session, claimed or
    not (the registry bootstrap a first sign-in still has ahead of it:
    probe, claim, legal acceptance); the default `:required` needs a
    claimed, authenticated caller.
  - `:permission` — a `Sanctum.Atoms` permission atom, enforced through
    `Sanctum.Context.require_permission/3`. Absent means any
    authenticated caller.
  - `:consent` — the consent surface class (`Sanctum.Consent.Authz`):
    `:interactive` admits interactive OIDC sessions only, `:staging` also
    admits API keys. The domain keeps its own finer Authz checks (the
    digest-pinned commit arm, conditional registration bindings) — dispatch
    applies the coarse class, the domain the exact one.
  - `:scope` — `:platform` admits only the server's operators
    (`Sanctum.Context.platform_admin`): the door verbs, and the one
    semaphore action that releases every athanor's slots. Everyone else is
    refused and does not see the action listed.
  - `:standing` — whether a person may pre-answer this action for calls
    nobody has seen yet. Absent means any standing scope a runner offers;
    `:thread` means a standing allow for one thread and no
    wider; `false` means never — every call is a click. `Aqua.ToolGrants`
    reads it at the grant write and the runner reads it off the approval
    intent, so both gates answer from this one declaration.
  """
  @type action_annotation :: %{
          required(:kind) => action_kind(),
          required(:planes) => [plane(), ...],
          optional(:auth) => :anonymous | :signed_in | :required,
          optional(:permission) => atom(),
          optional(:consent) => :interactive | :staging,
          optional(:scope) => :platform,
          optional(:standing) => :thread | false,
          # A read whose re-dispatch after an uncertain recovery is safe by
          # review: no effect beyond its answer. A recovered turn may
          # re-run only these; `kind: :read` alone says nothing about an
          # arbitrary endpoint. Refused by the boot audit on any other kind.
          optional(:recovery) => :replay_safe,
          optional(:host) => :intercepted
        }

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:operations) => [Cyfr.Ops.Operation.t(), ...],
          required(:input_schema) => map(),
          optional(:title) => String.t(),
          optional(:icons) => [icon()],
          optional(:output_schema) => map(),
          required(:annotations) => map()
        }

  @type handle_result :: {:ok, term()} | {:error, term()}

  @doc """
  Returns the service label used by `system.status` grouping and request-log `routed_to`.
  """
  @callback service() :: String.t()

  @doc """
  Return tools materialized from operation declarations.

  Each definition retains its canonical `operations`; `input_schema` and
  `annotations` are derived views. Optional title, icons and output schema
  describe the tool. Contextual permission and ownership checks remain the
  responsibility of the catalog and domain handler.
  """
  @callback tools() :: [tool_definition()]

  @doc """
  Handle a tool call.

  Called when an MCP client invokes a tool. The context contains
  the authenticated user and permissions.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback handle(tool_name :: String.t(), ctx :: term(), args :: map()) ::
              handle_result()

  @doc """
  The canonical invalid-action refusal, derived from the tool's action
  enum so the prose can never drift from the schema it restates.
  """
  @spec invalid_action(String.t(), [String.t()]) :: String.t()
  def invalid_action(tool, enum) when is_list(enum) and enum != [] do
    "Invalid #{tool} action. Use: #{humanize_enum(enum)}"
  end

  @doc "The action names from a tool's derived discovery schema."
  @spec action_enum(map()) :: [String.t()] | nil
  def action_enum(definition) when is_map(definition),
    do: get_in(definition, [:input_schema, "properties", "action", "enum"])

  defp humanize_enum([one]), do: one
  defp humanize_enum([a, b]), do: "#{a} or #{b}"

  defp humanize_enum(enum) do
    {init, [last]} = Enum.split(enum, -1)
    Enum.join(init, ", ") <> ", or " <> last
  end
end
