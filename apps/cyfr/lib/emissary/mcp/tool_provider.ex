# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolProvider do
  @moduledoc """
  Behaviour for MCP tool providers.

  Each CYFR service (Arca, Opus, etc.) implements this behaviour
  to register its tools with Emissary. This enables:

  1. **Service-owned tools**: Each service defines and handles its own tools
  2. **Decoupled transport**: Emissary stays domain-agnostic
  3. **Future distributed support**: Same interface works with :rpc.call

  ## Implementing a Provider

      defmodule Emissary.MCP.Tools.RecordsProvider do
        @behaviour Emissary.MCP.ToolProvider

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

  ## Future: Distributed Workers

  When running multiple Opus/Locus containers, the registry will be
  extended to track node availability and route accordingly:

      def handle(tool, ctx, args) do
        node = pick_healthy_node(tool)
        :rpc.call(node, __MODULE__, :handle, [tool, ctx, args])
      end

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

  `Emissary.MCP.ToolRegistry.do_call/4` enforces these keys at dispatch and
  `Emissary.MCP.ToolVisibility` derives discovery from the same map, so what
  a caller is shown and what a caller may invoke cannot drift apart.

  - `:auth` — `:anonymous` serves uncredentialed callers (device flow,
    health); `:signed_in` serves anyone holding a live session, claimed or
    not (the registry bootstrap a first sign-in still has ahead of it:
    probe, claim, legal acceptance); the default `:required` needs a
    claimed, authenticated caller.
  - `:permission` — a `Sanctum.Atoms` permission atom, enforced through
    `Sanctum.Context.require_permission_for_plane/2`. Absent means any
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
  """
  @type action_annotation :: %{
          required(:kind) => action_kind(),
          required(:planes) => [plane(), ...],
          optional(:auth) => :anonymous | :signed_in | :required,
          optional(:permission) => atom(),
          optional(:consent) => :interactive | :staging,
          optional(:scope) => :platform
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
    boot via `Emissary.MCP.ToolRegistry.audit_action_kinds/0`, which logs
    a warning per offender. Tests can call the function directly and
    assert on `:ok` to enforce zero drift in CI.

    External upstream MCP tools (proxied through
    `Emissary.MCP.ExternalProvider` and namespaced as `server:tool`) are
    classified as `:external` automatically by `Prism.AquaActions.kind_for/2`
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

  > #### Before adding `x-mcp-header` to an input schema {: .warning}
  >
  > No tool declares one today, which is why the server has nothing to check.
  > The moment one does, the specification's rule bites: "Any server that
  > processes the message body **MUST** validate that encoded header values,
  > after decoding if Base64-encoded, match the corresponding values in the
  > request body", and a client that omits the header while sending the value
  > **MUST** be rejected. Inbound validation lives in
  > `EmissaryWeb.Plugs.MCPRequestMetadata.check_mirrored_headers/2`, which currently
  > covers only `Mcp-Method` and `Mcp-Name`; extend it in the same change that
  > adds the annotation, or the mirrored header becomes a routing input nothing
  > verifies. `Emissary.MCP.ExternalServer` already implements the *client* half
  > for upstream servers that declare it.
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
  Report whether the provider is answering.

  `system.status` asks this. It used to ask by calling `handle/3` with an
  undeclared `"ping"` action — a verb absent from every `input_schema`
  enum, so no client could call it and no audit could see it, which made
  four providers carry a second, invisible entry point. A provider that
  does not implement this is simply reported as loaded or not.
  """
  @callback health() :: :ok | {:error, term()}

  @optional_callbacks health: 0
end
