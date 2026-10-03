# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire do
  @moduledoc """
  The gate's root facade: the one way into the operation table from
  outside Grimoire.

  Two entries dispatch, one per plane — `call_external/4` for a person,
  a key or the console, `call_in_chain/5` for a running chain under its
  authority — and every refusal either makes before a handler runs is a
  `%Prima.Refusal{stage: :admission}`. Streams have one entry of their
  own, `open_stream/3`, which admits a declared stream once and answers a
  bounded grant (`Grimoire.Streams`). The rest reads the table this
  member wrote at boot (`Grimoire.Catalog.load!/0`) and the annotations
  its declarations carry, classifies and renders a refusal, or cancels a
  call the gate is running. Every call either entry decides is recorded as one
  admission decision (`Grimoire.Decisions`), and an entry that decides on
  its own — a webhook, a schedule's fire — records its decision through
  `open_decision/3` and `close_decision/3`. `Grimoire.Catalog` is the
  implementation: outside Grimoire only the composition root names it, to
  load its table and install it as consent's port. `Grimoire.VirtualTools`
  declares the assistant's virtual tools, dispatched inside a formula
  rather than through the table; the gate classifies them from it, and
  Aqua and Compendium read it.
  """

  use Boundary,
    deps: [Sanctum, Arca],
    exports: [
      Catalog,
      Error,
      Proxy,
      RequestLog,
      RunningTasks,
      Supervisor,
      VirtualTools
    ],
    check: [aliases: true]

  alias Grimoire.{Annotations, Catalog, Resources, RunningTasks}

  @doc "Call a tool from the external plane (`Grimoire.Catalog.call_external/4`)."
  @spec call_external(String.t(), Sanctum.Context.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_external(name, ctx, args, opts \\ []), to: Catalog

  @doc "Call a tool from inside a running chain (`Grimoire.Catalog.call_in_chain/5`)."
  @spec call_in_chain(String.t(), Sanctum.Context.t(), term(), Prima.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_in_chain(name, ctx, args, authority, opts \\ []), to: Catalog

  @doc """
  Open a declared stream (`Grimoire.Streams.open/3`): one decision, and a
  `Prima.StreamGrant` naming the stream's bus roster key, its projection,
  the subject and the deadline, or the admission refusal. `subject` is
  nil for a stream that takes none. The delivery owner above the gate
  subscribes and enforces the grant.
  """
  @spec open_stream(Sanctum.Context.t(), String.t(), String.t() | nil) ::
          {:ok, Prima.StreamGrant.t()} | {:error, Prima.Refusal.t()}
  defdelegate open_stream(ctx, name, subject \\ nil), to: Grimoire.Streams, as: :open

  @doc """
  Every stream the providers declare, as plain data sorted by name
  (`Grimoire.Catalog.streams/0`).
  """
  @spec streams() :: [Prima.Provider.Stream.t()]
  defdelegate streams(), to: Catalog

  @doc """
  Record an admission decision an entry made on its own, with its
  request-log row (`Grimoire.Decisions.open/3`). Always `:ok`: audit never
  decides the operation's outcome.
  """
  @spec open_decision(Sanctum.Context.t() | nil, Prima.Decision.t(), map()) :: :ok
  defdelegate open_decision(ctx, decision, projection \\ %{}), to: Grimoire.Decisions, as: :open

  @doc """
  Record how an admitted call ended, on its decision and its request-log
  row (`Grimoire.Decisions.close/3`). Always `:ok`.
  """
  @spec close_decision(Sanctum.Context.t() | nil, String.t(), map()) :: :ok
  defdelegate close_decision(ctx, call_id, completion), to: Grimoire.Decisions, as: :close

  @doc """
  A refusal an entry makes before the gate, as the decision `open_decision/3`
  records (`Grimoire.Decisions.refused/3`): the reason's class and sentence,
  the context's identity or none, the plane, the names the entry knows.
  """
  @spec refused_decision(Sanctum.Context.t() | nil, term(), keyword() | map()) ::
          Prima.Decision.t()
  defdelegate refused_decision(ctx, reason, fields), to: Grimoire.Decisions, as: :refused

  @doc """
  The public sentence for any refusal, whichever vocabulary it came from
  (`Grimoire.Error.render/1`): never `nil`, never an `inspect/1` of the
  term.
  """
  @spec render(term()) :: String.t()
  defdelegate render(reason), to: Grimoire.Error

  @doc "The normalized refusal for any reason (`Grimoire.Error.classify/1`)."
  @spec classify(term()) :: Prima.Refusal.t()
  defdelegate classify(reason), to: Grimoire.Error

  @doc "The wire code a refusal carries in place of its class's, or nil (`Grimoire.Error.code_override/1`)."
  @spec code_override(Prima.Refusal.t()) :: atom() | nil
  defdelegate code_override(refusal), to: Grimoire.Error

  @doc "The action map a tool definition declares, in any spelling (`Grimoire.Annotations.actions_of/1`)."
  @spec declared_actions(Annotations.source()) :: %{optional(String.t()) => map()}
  defdelegate declared_actions(tool_def), to: Annotations, as: :actions_of

  @doc "An action's declared kind, or nil (`Grimoire.Annotations.kind/2`)."
  @spec annotation_kind(Annotations.source(), String.t() | nil) :: atom() | nil
  defdelegate annotation_kind(tool_def, action), to: Annotations, as: :kind

  @doc "An action's declared standing rule, or nil for none (`Grimoire.Annotations.standing/2`)."
  @spec annotation_standing(Annotations.source(), String.t() | nil) :: :thread | false | nil
  defdelegate annotation_standing(tool_def, action), to: Annotations, as: :standing

  @doc "`:replay_safe` for a read declared safe to re-dispatch, nil otherwise (`Grimoire.Annotations.recovery/2`)."
  @spec annotation_recovery(Annotations.source(), String.t()) :: :replay_safe | nil
  defdelegate annotation_recovery(tool_def, action), to: Annotations, as: :recovery

  @doc "A standing value in any spelling, decoded (`Grimoire.Annotations.standing/1`)."
  @spec standing_scope(term()) :: :thread | false | nil
  defdelegate standing_scope(value), to: Annotations, as: :standing

  @doc "A standing value as the intent carries it (`Grimoire.Annotations.standing_to_wire/1`)."
  @spec standing_to_wire(term()) :: String.t() | false | nil
  defdelegate standing_to_wire(value), to: Annotations

  @doc "The concrete resources the providers advertise (`Grimoire.Resources.list_resources/0`)."
  @spec list_resources() :: [map()]
  defdelegate list_resources(), to: Resources

  @doc "The resource templates the providers advertise (`Grimoire.Resources.list_resource_templates/0`)."
  @spec list_resource_templates() :: [map()]
  defdelegate list_resource_templates(), to: Resources

  @doc "The tool and action a resource URI reads (`Grimoire.Resources.resolve/1`)."
  @spec resolve_resource(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, {:invalid_argument, String.t()}}
  defdelegate resolve_resource(uri), to: Resources, as: :resolve

  @doc "The tool definitions a context may see, narrowed to its actions (`Grimoire.Visibility.filter_for_context/2`)."
  @spec visible_tools([map()], Sanctum.Context.t()) :: [map()]
  defdelegate visible_tools(tools, ctx), to: Grimoire.Visibility, as: :filter_for_context

  @doc "A tool's provider and its declarations: `{:ok, {module, tool}}` or `:miss`."
  @spec lookup(String.t()) :: {:ok, {module(), map()}} | :miss
  defdelegate lookup(name), to: Catalog

  @doc "A tool's wire definition, as `tools/list` serves it."
  @spec get_tool(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_tool(name), to: Catalog

  @doc """
  What `tool.action` is: a virtual hand's kind, `:external` for a
  `server:tool`, else the catalogued tool's declared kind, nil when
  unknown (`Grimoire.Catalog.tool_kind/2`).
  """
  @spec tool_kind(String.t(), String.t()) :: atom() | nil
  defdelegate tool_kind(tool, action), to: Catalog

  @doc "The action verbs a virtual hand or a catalogued tool has, `[]` for neither (`Grimoire.Catalog.tool_actions/1`)."
  @spec tool_actions(String.t()) :: [String.t()]
  defdelegate tool_actions(tool), to: Catalog

  @doc "A wire tool definition narrowed to `actions`."
  @spec restrict_tool(map(), [String.t()]) :: map()
  defdelegate restrict_tool(tool_def, actions), to: Catalog

  @doc "Every tool the table holds, as `tools/list` serves it, sorted by name."
  @spec list_tools() :: [map()]
  defdelegate list_tools(), to: Catalog

  @doc "Whether a running chain can run `tool.action`, through the table or the host."
  @spec chain_reachable?(String.t(), String.t() | nil) :: boolean()
  defdelegate chain_reachable?(name, action), to: Catalog

  @doc "Whether the table knows `tool.action` and refuses it to every chain."
  @spec in_chain_refused?(String.t(), String.t() | nil) :: boolean()
  defdelegate in_chain_refused?(name, action), to: Catalog

  @doc "Whether the host, not the table, runs `tool.action` for a chain."
  @spec host_intercepted?(String.t(), String.t() | nil) :: boolean()
  defdelegate host_intercepted?(name, action), to: Catalog

  @doc "Every `tool.action` annotated `host: :intercepted`, sorted."
  @spec host_intercepted_actions() :: [String.t()]
  defdelegate host_intercepted_actions(), to: Catalog

  @doc "Every provider named in `config :cyfr, :tool_providers`, loaded or not."
  @spec configured_providers() :: [module()]
  defdelegate configured_providers(), to: Catalog

  @doc "The operation table: tool name → `{provider, tool}`."
  @spec operations() :: %{String.t() => {module(), map()}}
  defdelegate operations(), to: Catalog

  @doc "The resource index (`Grimoire.Resources`)."
  @spec resources() :: Grimoire.Resources.table()
  defdelegate resources(), to: Grimoire.Resources, as: :table

  @doc """
  Stop the supervised handler of the call named by `handle`: a running
  handler is killed and a claimed one never runs. A handle released or
  never claimed is left alone, with nothing written for it.
  """
  @spec cancel_call(term()) :: :ok
  defdelegate cancel_call(handle), to: RunningTasks, as: :cancel_handle

  @doc """
  Forget a call's cancellation handle once its caller is done with it:
  a later cancel of it does nothing.
  """
  @spec release_call(term()) :: :ok
  defdelegate release_call(handle), to: RunningTasks, as: :release_handle

  @doc """
  Stop the supervised calls running under an ingress request id:
  `{:error, :not_found}` when none runs under it any longer.
  """
  @spec cancel_request(String.t()) :: :ok | {:error, :not_found}
  defdelegate cancel_request(request_id), to: RunningTasks, as: :cancel
end
