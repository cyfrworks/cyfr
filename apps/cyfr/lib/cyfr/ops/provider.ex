# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Provider do
  @moduledoc """
  Behaviour for MCP tool providers.

  Each CYFR service (Arca, Opus, etc.) implements this behaviour
  to register its tools with Emissary. This enables:

  1. **Service-owned tools**: Each service defines and handles its own tools
  2. **Decoupled transport**: Emissary stays domain-agnostic

  ## Implementing a Provider

      defmodule Emissary.MCP.Tools.RecordsProvider do
        @behaviour Cyfr.Ops.Provider

        @impl true
        def tools do
          [
            %{
              name: "retention",
              description: "Manage data retention policies",
              input_schema: %{"type" => "object", ...}
            }
          ]
        end

        @impl true
        def handle("retention", ctx, args) do
          # Implementation
          {:ok, %{settings: %{...}}}
        end
      end

  ## Registration

  Providers are configured in `config/config.exs`:

      config :cyfr, :tool_providers, [
        Emissary.MCP.Tools.RecordsProvider,
        Sanctum.MCP,
        Opus.MCP,
        Compendium.MCP
      ]

  Providers are in-process by design — remote workers are a protocol
  project, not an `:rpc.call` on this behaviour. `Opus.HostSurfaceTest`
  is where the size of that project is written down: the engine names some
  forty cyfr modules, so a worker needs a client for each, not a routing
  patch.

  ## The shape of an answer

  One convention for what `handle/3` puts in `{:ok, result}`, so a client
  (and the AQUA harness reading a tool's answer back onto the tape) can
  read any tool the same way:

    * a **list** action answers a map keyed by the plural of what it
      lists — `%{notes: [...]}`, `%{guides: [...]}`, `%{skills: [...]}` —
      beside which a `count`, a `scope` or a `hint` may ride;
    * a **single read** answers the record itself — `get` and `read`
      return the fields, not a wrapper;
    * a **write** answers the verb's past tense as the key and the
      subject as the value — `%{created: name}`, `%{updated: name}`,
      `%{deleted: name}`, `%{kept: name}`, `%{pinned: name}`,
      `%{forgot: name}`, `%{decided: "approved"}` — with whatever the
      caller must know beside it (`replaced: true`, `restored: "shipped"`,
      the `athanor_id` a note landed in).

  A search is a list: `notes.search` answers `%{matches: [...]}`, the
  plural of what a search yields rather than of what it searched.
  """

  alias Sanctum.Context

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
    `:conversation` means a standing allow for one conversation and no
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
          optional(:standing) => :conversation | false,
          # A read whose re-dispatch after an uncertain recovery is safe by
          # review: no effect beyond its answer. A recovered turn may
          # re-run only these; `kind: :read` alone says nothing about an
          # arbitrary endpoint. Refused by the boot audit on any other kind.
          optional(:recovery) => :replay_safe
        }

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map(),
          optional(:title) => String.t(),
          optional(:icons) => [icon()],
          optional(:output_schema) => map(),
          optional(:annotations) => map()
        }

  @type handle_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Returns the service label used by `system.status` grouping and request-log `routed_to`.
  """
  @callback service() :: String.t()

  @doc """
  Return list of tool definitions this provider offers.

  Each tool definition must include:
  - `name`: Tool name (e.g., "storage", "execution", "component")
  - `description`: Human-readable description for AI agents
  - `input_schema`: JSON Schema for input validation

  Optional fields:
  - `title`: Human-readable display name for the tool
  - `icons`: Array of icon definitions for UI display
  - `output_schema`: JSON Schema for output validation
  - `annotations`: Properties describing tool behavior. Spec-conformant tool-level
    boolean hints (`readOnlyHint`, `destructiveHint`, `idempotentHint`,
    `openWorldHint`) live here. CYFR adds a per-action extension to the same
    map for the AQUA harness:

        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "list"   => %{kind: :read},
            "set"    => %{kind: :write},
            "delete" => %{kind: :destructive}
          }
        }

    `actions[name].kind` is one of `:read | :write | :execute | :destructive`.
    `:read` is no-state-change, `:write` is recoverable mutation, `:execute`
    runs code or hits external/billable systems, `:destructive` is
    irreversible.

    The same per-action map carries the access declaration (`auth`,
    `permission`, `consent` — see `t:action_annotation/0`), which the
    dispatcher enforces and discovery derives from. A handler may keep
    residual checks the annotation cannot express (tenant presence,
    ownership, definition authority, the domain's own consent arms), but
    never a plain permission gate — that lives here.

    Every action listed in the tool's
    `input_schema.properties.action.enum` MUST have a matching key in
    `annotations.actions` with an explicit `kind`. Drift is surfaced at
    boot via `Cyfr.Ops.Catalog.audit_action_kinds/0`, which logs
    a warning per offender. Tests can call the function directly and
    assert on `:ok` to enforce zero drift in CI.

    External upstream MCP tools (proxied through
    `Emissary.MCP.ExternalProvider` and namespaced as `server:tool`) are
    classified as `:external` automatically by `Aqua.Kinds.kind_for/2`
    and don't need per-action annotations.

  ### Canonical action verbs

    Naming guideline (not enforced — `kind` is the source of truth). Use
    these verbs across providers so AQUA's "what does `delete` mean"
    intuition lines up:

    - `:read` — `get`, `list`, `search`, `inspect`, `read`, `status`,
      `stats`, `whoami`, `validate`, `categories`
    - `:write` — `create`, `update`, `set`, `patch`, `enable`, `disable`,
      `pause`, `resume`, `rotate`, `revoke`, `grant`, `register`, `pull`,
      `publish`, `notify`, `refresh`
    - `:execute` — `run`, `execute`, `compile`, `test`, `probe`, `discover`
    - `:destructive` — `delete`, `force_release`, `cleanup`, `yank`,
      `deprecate`

    Compound or sub-resource verbs (`members_add`, `tokens_issue`,
    `device_init`, `re_resolve`, `claim_personal`, `legal_accept`, …) are
    fine when the domain warrants them; ship them with an explicit `kind`
    matching the closest canonical bucket.

  Tools with `x-mcp-header` annotations require validation that decoded
  header values match the corresponding request body values. Missing headers
  for supplied values must be rejected. The inbound validator,
  `EmissaryWeb.Plugs.MCPRequestMetadata.check_mirrored_headers/2`, currently
  covers `Mcp-Method` and `Mcp-Name` only; no local tool declares custom
  mirrored headers. `Emissary.MCP.ExternalServer` handles these annotations
  when calling upstream servers.
  """
  @callback tools() :: [tool_definition()]

  @doc """
  Handle a tool call.

  Called when an MCP client invokes a tool. The context contains
  the authenticated user and permissions.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback handle(tool_name :: String.t(), ctx :: Context.t(), args :: map()) ::
              handle_result()

  @doc """
  The canonical invalid-action refusal, derived from the tool's action
  enum so the prose can never drift from the schema it restates.
  """
  @spec invalid_action(String.t(), [String.t()]) :: String.t()
  def invalid_action(tool, enum) when is_list(enum) and enum != [] do
    "Invalid #{tool} action. Use: #{humanize_enum(enum)}"
  end

  @doc """
  The action enum out of a tool's own wire definition — the one place that
  knows where the schema keeps it. Eight providers carried the identical
  `get_in(definition(), ["properties", "action", "enum"])` line; the path
  is this module's knowledge, not theirs.
  """
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
