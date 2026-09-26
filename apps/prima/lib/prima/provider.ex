# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Provider do
  @moduledoc """
  Behaviour for built-in operation providers.

  Providers declare actions with `Prima.Operation` and return tools
  materialized by `Prima.Operation.tool/2`. Arguments, discovery schemas
  and access/effect annotations derive from those declarations. The host
  catalog performs contextual authorization before invoking `handle/3`.

  What `handle/3` receives is declared by the provider (`c:context_kind/0`):
  the caller's authenticated domain context by default, or the actor the
  gate projects from it once the call is authorized. The context is opaque
  at this shared boundary. This behaviour contains no running catalog or
  infrastructure dependency.

  A provider that serves MCP resources advertises them with
  `c:resources/0` and `c:resource_templates/0`; each advertised scheme is
  read through the one operation that declares it in `resource_schemes`
  (`Prima.Operation`).

  A provider that offers streams declares them beside its operations with
  `c:streams/0` (`Prima.Provider.Stream`): a stream is continuous data a
  gate-admitted grant opens (`Prima.StreamGrant`), riding one `Cyfr.Bus`
  topic, and never an operation of its own.

  Handlers return `{:ok, result}` or `{:error, reason}`. List results use a
  plural resource key with optional count or pagination metadata; single
  reads return the record, and mutations return their resulting state.
  """

  defmodule Stream do
    @moduledoc """
    One stream a provider offers (`c:Prima.Provider.streams/0`), declared
    where its operations are.

      * `name` — two or more dotted lowercase identifiers
        (`executions.deltas`), the name a tincture declares and opens it by
        (`Prima.Manifest.Tincture`).
      * `topic` — the `Cyfr.Bus` roster key of the topic it rides; the host
        checks at boot that the roster declares it.
      * `projection` — the payload fields a grant forwards to its holder, and
        nothing else of the topic's payload.
      * `subject` — the grammar a subject must match, as the source of an
        anchored regular expression, or `nil` for a stream that takes no
        subject.
      * `deadline_bound` — the longest a grant on it lives, in seconds; a
        grant's own deadline is never later.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            topic: atom(),
            projection: [String.t()],
            subject: String.t() | nil,
            deadline_bound: pos_integer()
          }

    @enforce_keys [:name, :topic, :projection, :deadline_bound]
    defstruct [:name, :topic, :projection, :deadline_bound, subject: nil]

    @field ~r/\A[a-z][a-z0-9_]{0,62}\z/

    @doc """
    Whether `stream` is a well-formed declaration: a stream name, an atom
    topic, a non-empty list of distinct field names, a subject grammar that
    compiles and is anchored at both ends (or none), and a positive bound.
    """
    @spec valid?(term()) :: boolean()
    def valid?(%__MODULE__{} = stream) do
      Prima.Manifest.Tincture.stream_name?(stream.name) and is_atom(stream.topic) and
        stream.topic not in [nil, true, false] and
        projection?(stream.projection) and subject_grammar?(stream.subject) and
        is_integer(stream.deadline_bound) and stream.deadline_bound > 0
    end

    def valid?(_other), do: false

    @doc """
    Whether the stream admits `subject`: `nil` for a stream that takes none,
    or a string its grammar matches whole.
    """
    @spec admits?(t(), String.t() | nil) :: boolean()
    def admits?(%__MODULE__{subject: nil}, subject), do: is_nil(subject)

    def admits?(%__MODULE__{subject: grammar}, subject) when is_binary(subject) do
      case Regex.compile(grammar) do
        {:ok, regex} -> Regex.match?(regex, subject)
        {:error, _} -> false
      end
    end

    def admits?(%__MODULE__{}, _subject), do: false

    defp projection?(fields) when is_list(fields) and fields != [],
      do:
        Enum.all?(fields, &(is_binary(&1) and Regex.match?(@field, &1))) and
          Enum.uniq(fields) == fields

    defp projection?(_fields), do: false

    # Anchored at both ends, so a grammar cannot admit a subject by matching
    # a part of it.
    defp subject_grammar?(nil), do: true

    defp subject_grammar?(grammar) when is_binary(grammar) do
      String.starts_with?(grammar, "\\A") and String.ends_with?(grammar, "\\z") and
        match?({:ok, _}, Regex.compile(grammar))
    end

    defp subject_grammar?(_grammar), do: false
  end

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

  The gate (`Grimoire.call_external/4`, `Grimoire.call_in_chain/5`)
  enforces these keys at dispatch and `Grimoire.Visibility` derives
  discovery from the same map, so what a caller is shown and what a
  caller may invoke cannot drift apart.

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
    execution action that releases every athanor's slots. Everyone else is
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
          required(:operations) => [Prima.Operation.t(), ...],
          required(:input_schema) => map(),
          optional(:title) => String.t(),
          optional(:icons) => [icon()],
          optional(:output_schema) => map(),
          required(:annotations) => map()
        }

  @type handle_result :: {:ok, term()} | {:error, term()}

  @typedoc """
  What a provider's `handle/3` is given as its second argument.

  `:context` — the caller's authenticated domain context, as the gate
  authorized it (the default). `:actor` — the `Prima.Actor` the gate
  projects from that context after authentication, consent, argument
  validation and lineage, and nothing else: no credential, no permission
  set, no session. A provider below the identity domain declares `:actor`.
  """
  @type context_kind :: :context | :actor

  @context_kinds [:context, :actor]

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
  What `handle/3` receives: `:context` (the default when not exported) or
  `:actor`. Any other value refuses the catalog's boot.
  """
  @callback context_kind() :: context_kind()

  @doc """
  The concrete resources a provider advertises for MCP `resources/list`:
  maps with `:uri`, `:name` and optionally `:description` and `:mimeType`.
  """
  @callback resources() :: [map()]

  @doc """
  The RFC 6570 resource templates a provider advertises for MCP
  `resources/templates/list`: maps with `:uriTemplate`, `:name` and
  optionally `:description` and `:mimeType`.
  """
  @callback resource_templates() :: [map()]

  @doc """
  The health of the services a provider depends on, for `system.status`:
  service name to state (`"ok"`, `"disabled"`, `"unreachable"`, …).
  A degraded service is a state in the map, never a failed call.
  """
  @callback status() :: %{String.t() => String.t()}

  @doc """
  The streams a provider offers (`Prima.Provider.Stream`): `[]` when it
  exports none. Each names the `Cyfr.Bus` topic it rides, which the host
  checks exists at boot.
  """
  @callback streams() :: [Prima.Provider.Stream.t()]

  @optional_callbacks context_kind: 0, resources: 0, resource_templates: 0, status: 0, streams: 0

  @doc """
  A provider's declared `c:context_kind/0`: `:context` when it exports
  none. A value outside `:context | :actor` raises, so a provider that
  declares something the gate cannot honour is refused rather than handed
  a full context by default.
  """
  @spec context_kind(module()) :: context_kind()
  def context_kind(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :context_kind, 0) do
      case module.context_kind() do
        kind when kind in @context_kinds ->
          kind

        other ->
          raise ArgumentError,
                "#{inspect(module)}.context_kind/0 answered #{Prima.LoggerContext.shape(other)}; " <>
                  "a provider's handler input is :context or :actor"
      end
    else
      :context
    end
  end

  @doc """
  A provider's declared `c:streams/0`: `[]` when it exports none. A
  declaration that is not a list of well-formed `Prima.Provider.Stream`s
  with distinct names raises, so a provider that declares a stream the
  gate cannot honour is refused at boot rather than served.
  """
  @spec streams(module()) :: [Prima.Provider.Stream.t()]
  def streams(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :streams, 0) do
      declared = module.streams()

      cond do
        not (is_list(declared) and Enum.all?(declared, &Prima.Provider.Stream.valid?/1)) ->
          raise ArgumentError,
                "#{inspect(module)}.streams/0 answered #{Prima.LoggerContext.shape(declared)}; " <>
                  "a provider's streams are a list of well-formed %Prima.Provider.Stream{}"

        length(Enum.uniq_by(declared, & &1.name)) != length(declared) ->
          raise ArgumentError, "#{inspect(module)}.streams/0 declares a stream name twice"

        true ->
          declared
      end
    else
      []
    end
  end

  @doc """
  The stream `name` among `declared` (every provider's `streams/1`,
  concatenated), or `{:error, :undeclared_stream}` when no provider
  declares it.
  """
  @spec fetch_stream([Prima.Provider.Stream.t()], String.t()) ::
          {:ok, Prima.Provider.Stream.t()} | {:error, :undeclared_stream}
  def fetch_stream(declared, name) when is_list(declared) and is_binary(name) do
    case Enum.find(declared, &match?(%Prima.Provider.Stream{name: ^name}, &1)) do
      nil -> {:error, :undeclared_stream}
      stream -> {:ok, stream}
    end
  end

  @doc """
  The scheme an advertised resource URI or URI template names: the text
  before `://`, when there is some. The one reading of an advertised URI,
  shared by the catalog's boot audit and the resource adapter's lookup.
  """
  @spec resource_scheme(term()) :: {:ok, String.t()} | :error
  def resource_scheme(uri) when is_binary(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, _rest] when scheme != "" -> {:ok, scheme}
      _ -> :error
    end
  end

  def resource_scheme(_uri), do: :error

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
