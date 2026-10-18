# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Decision do
  @moduledoc """
  The `decision` tool over the decision record (`Arca.DecisionLog`): each
  call the gate, or an entry deciding on its own, admitted or refused. The
  decisions are security rows, so Sanctum is their one reader.

  The provider declares `context_kind: :actor`: the gate authorizes every
  call with the caller's full context and hands these handlers the
  `Prima.Actor` it projects, and nothing else.

  `list`, `get` and `correlate` read the caller's athanor's decisions,
  never a row without a tenant. `list_global` and `get_global` read every
  tenant's and the host's own: they are the platform admin's
  (`scope: :platform`, which the gate checks against the operator
  capability), and the log refuses any other actor again.

  `correlate` joins the request's decisions to what else it left behind,
  through the request log's correlation (`Sanctum.Providers.McpLog`).
  """

  @behaviour Prima.Provider

  alias Sanctum.Providers.McpLog

  @impl true
  def service, do: "sanctum"

  @impl true
  def context_kind, do: :actor

  @impl true
  def tools, do: [decision_tool()]

  # The tenant readers take `storage_read`; the global readers are the
  # platform admin's, which the gate checks as the operation's scope.
  defp decision_tool do
    alias Prima.{Arg, Operation}

    filters = [
      Arg.new("request_id", :string,
        description:
          "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
      ),
      Arg.new("tool", :string, description: "Tool name filter"),
      Arg.new("admission", :string,
        enum: Enum.map(Prima.Decision.admissions(), &Atom.to_string/1),
        description: "Filter by admission"
      ),
      Arg.new("refusal_class", :string, description: "Filter by refusal class"),
      Arg.new("since", :string,
        description: "ISO8601 timestamp — return decisions made at or after this time"
      ),
      Arg.new("limit", :integer, description: "Max results (default: 20)")
    ]

    call_id = [Arg.new("call_id", :string, required: true, description: "Call ID")]

    Operation.tool(
      [
        Operation.new("decision", "list", "List decision", filters,
          kind: :read,
          recorded: false,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new("decision", "get", "Get decision", call_id,
          kind: :read,
          recorded: false,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new(
          "decision",
          "correlate",
          "Correlate decision",
          [
            Arg.new("request_id", :string,
              required: true,
              description:
                "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
            )
          ],
          kind: :read,
          recorded: false,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new(
          "decision",
          "list_global",
          "List global decision",
          filters ++
            [
              Arg.new("athanor_id", :string,
                description: "global only: one athanor's decisions, or none for the host's own"
              )
            ],
          kind: :read,
          recorded: false,
          planes: [:external],
          scope: :platform,
          permission: :storage_read
        ),
        Operation.new("decision", "get_global", "Get global decision", call_id,
          kind: :read,
          recorded: false,
          planes: [:external],
          scope: :platform,
          permission: :storage_read
        )
      ],
      description:
        "Query admission decisions - list, get, or correlate the calls admitted or refused",
      title: "Admission Decisions"
    )
  end

  # ============================================================================
  # Handlers
  # ============================================================================

  @impl true
  def handle("decision", %Prima.Actor{} = actor, %{"action" => "list"} = args) do
    with {:ok, opts} <- decision_filters(args) do
      actor |> Arca.DecisionLog.list(opts) |> decisions_answer()
    end
  end

  def handle("decision", %Prima.Actor{} = actor, %{"action" => "get", "call_id" => call_id})
      when is_binary(call_id) do
    actor |> Arca.DecisionLog.get(call_id) |> decision_answer(call_id)
  end

  # The decisions leg is the tool's own, so a store that cannot answer it
  # is a refusal; the legs it is joined with stay best-effort, as they
  # are in `mcp_log.correlate`.
  def handle("decision", %Prima.Actor{} = actor, %{
        "action" => "correlate",
        "request_id" => request_id
      })
      when is_binary(request_id) do
    case Arca.DecisionLog.correlate(actor, request_id) do
      {:ok, rows} ->
        {:ok,
         Map.put(
           McpLog.correlation(actor, request_id),
           :decisions,
           Enum.map(rows, &decision_to_map/1)
         )}

      {:error, reason} ->
        {:error, decision_refusal(reason, request_id)}
    end
  end

  def handle("decision", %Prima.Actor{} = actor, %{"action" => "list_global"} = args) do
    with {:ok, opts} <- decision_filters(args),
         {:ok, opts} <- global_tenant(opts, args["athanor_id"]) do
      actor |> Arca.DecisionLog.list_global(opts) |> decisions_answer()
    end
  end

  def handle("decision", %Prima.Actor{} = actor, %{
        "action" => "get_global",
        "call_id" => call_id
      })
      when is_binary(call_id) do
    actor |> Arca.DecisionLog.get_global(call_id) |> decision_answer(call_id)
  end

  def handle("decision", %Prima.Actor{}, %{"action" => action})
      when action in ["get", "get_global"] do
    {:error, {:invalid_argument, "Missing required argument: call_id"}}
  end

  def handle("decision", %Prima.Actor{}, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  def handle("decision", %Prima.Actor{}, _args) do
    {:error, Prima.Provider.invalid_action("decision", action_enum("decision"))}
  end

  def handle(tool, %Prima.Actor{}, _args), do: {:error, {:not_found, "tool", tool}}

  # ============================================================================
  # The decision projection
  # ============================================================================

  @doc false
  # A decision as the wire carries it: every `Prima.Decision` field under
  # its own name, vocabulary atoms as their names and times as ISO8601.
  # The request log's correlation renders its decisions leg through it.
  @spec decision_to_map(Prima.Decision.t()) :: %{String.t() => term()}
  def decision_to_map(%Prima.Decision{} = decision) do
    Map.new(Map.from_struct(decision), fn {field, value} ->
      {Atom.to_string(field), decision_value(value)}
    end)
  end

  defp decision_value(%DateTime{} = value), do: format_datetime(value)
  defp decision_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp decision_value(value), do: value

  defp decisions_answer({:ok, rows}), do: {:ok, %{decisions: Enum.map(rows, &decision_to_map/1)}}
  defp decisions_answer({:error, reason}), do: {:error, decision_refusal(reason, nil)}

  defp decision_answer({:ok, row}, _call_id), do: {:ok, %{decision: decision_to_map(row)}}
  defp decision_answer({:error, reason}, call_id), do: {:error, decision_refusal(reason, call_id)}

  # The decision log's refusals as the wire renders them. `:forbidden` is
  # the log's own refusal of an actor the gate should already have
  # refused: it reads as the same missing capability.
  defp decision_refusal(:no_athanor, _id), do: :missing_tenant
  defp decision_refusal(:not_found, id), do: {:not_found, "Decision", id}
  defp decision_refusal(:forbidden, _id), do: :platform_admin_required
  defp decision_refusal(:database_error, _id), do: {:unavailable, "Storage"}

  # The filters `list` and `list_global` share, typed as the log reads
  # them. A name outside the vocabulary is the caller's error, never a
  # filter that silently matches nothing.
  defp decision_filters(args) do
    opts =
      [limit: args["limit"] || 20]
      |> maybe_put(:request_id, args["request_id"])
      |> maybe_put(:tool, args["tool"])

    with {:ok, opts} <- McpLog.since_opt(opts, args["since"]),
         {:ok, opts} <-
           vocabulary_opt(opts, :admission, args["admission"], Prima.Decision.admissions()) do
      vocabulary_opt(opts, :refusal_class, args["refusal_class"], Prima.Refusal.classes())
    end
  end

  defp vocabulary_opt(opts, _key, nil, _vocabulary), do: {:ok, opts}

  defp vocabulary_opt(opts, key, name, vocabulary) do
    case Enum.find(vocabulary, &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:invalid_argument, "Unknown #{key}: #{name}"}}
      atom -> {:ok, Keyword.put(opts, key, atom)}
    end
  end

  defp global_tenant(opts, nil), do: {:ok, opts}
  defp global_tenant(opts, "none"), do: {:ok, Keyword.put(opts, :athanor_id, :none)}

  defp global_tenant(opts, id) when is_binary(id) and id != "",
    do: {:ok, Keyword.put(opts, :athanor_id, id)}

  defp global_tenant(_opts, _id),
    do: {:error, {:invalid_argument, "athanor_id must be an athanor id or none"}}

  # ============================================================================
  # Internal
  # ============================================================================

  defp format_datetime(value), do: Prima.Time.iso8601(value)

  # `Arca.QueryHelpers.maybe_put/3`, which Arca does not export.
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp action_enum(tool) do
    [tool_def] = for t <- tools(), t.name == tool, do: t
    get_in(tool_def, [:input_schema, "properties", "action", "enum"])
  end
end
