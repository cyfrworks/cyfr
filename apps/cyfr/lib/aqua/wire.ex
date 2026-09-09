# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Wire do
  @moduledoc """
  The `aqua-actions` text-intent protocol: the fenced block an agent ends
  a reply with, parsed and validated into intents.

  `parse/2` extracts the validated intents from a complete assistant
  message against the calling agent's `tool_policy`, returning
  `%{stripped, intents, drops}`; `strip_blocks/1` is the render-time
  strip for partial blocks; `validate/2` judges one entry. A
  `ui.request_approval` carries a `proposal: {tool, action, args}` the
  allowlist must mark `ask`; the proposal is canonicalised first, so a
  card is always for the operation it is. Every other kind is a
  navigation or UI intent, judged by `Aqua.Intents`.
  """

  @block_re ~r/```aqua-actions[ \t]*\r?\n(.*?)```/s

  @render_strip_re ~r/```aqua-actions[ \t]*\r?\n.*?(```|\z)/s

  # Risk values for `ui.request_approval`. Prism derives the card's risk from

  # the action's `kind`; the hinted value stays part of the intent shape.

  @allowed_risks ~w(low medium high)

  @doc """
  Strip every `aqua-actions` block (closed or mid-stream) from a text chunk
  for display. Safe-for-rendering — does not parse or validate.
  """

  @spec strip_blocks(String.t()) :: String.t()

  def strip_blocks(content) when is_binary(content) do
    Regex.replace(@render_strip_re, content, "")
  end

  def strip_blocks(content), do: content

  @doc """
  Parse closed `aqua-actions` blocks out of a complete assistant message.

  `tool_policy` is the calling agent's allowlist (string keys `"tool.action"`
  or `"tool.*"` globs, values `"ask" | "auto"`). Used to validate
  `ui.request_approval` proposals — only `"ask"` actions may be requested.

  Returns:

      %{
        stripped: "<message minus all blocks, trimmed>",
        intents:  [%{kind: "navigate", to: "/path"}, ...],
        drops:    [%{raw: term, reason: String.t()}, ...]   # policy refusals also carry tag: atom
      }
  """

  @spec parse(String.t(), map()) :: %{
          stripped: String.t(),
          intents: [map()],
          drops: [map()]
        }

  def parse(content, tool_policy \\ %{})

  def parse(content, tool_policy) when is_binary(content) and is_map(tool_policy) do
    {intents, drops} = collect(content, tool_policy, [], [])
    stripped = @block_re |> Regex.replace(content, "") |> String.trim()

    %{stripped: stripped, intents: Enum.reverse(intents), drops: Enum.reverse(drops)}
  end

  def parse(_, _), do: %{stripped: "", intents: [], drops: []}

  defp collect(content, tool_policy, intents, drops) do
    case Regex.scan(@block_re, content, capture: :all_but_first) do
      [] ->
        {intents, drops}

      bodies ->
        Enum.reduce(bodies, {intents, drops}, fn [body], {is, ds} ->
          process_body(body, tool_policy, is, ds)
        end)
    end
  end

  defp process_body(body, tool_policy, intents, drops) do
    case Jason.decode(body) do
      {:ok, parsed} when is_list(parsed) ->
        Enum.reduce(parsed, {intents, drops}, fn entry, {is, ds} ->
          case validate(entry, tool_policy) do
            {:ok, intent} ->
              {[intent | is], ds}

            {:error, {tag, reason}} when is_atom(tag) and is_binary(reason) ->
              {is, [%{raw: entry, reason: reason, tag: tag} | ds]}

            {:error, reason} ->
              {is, [%{raw: entry, reason: reason} | ds]}
          end
        end)

      {:ok, other} ->
        {intents, [%{raw: other, reason: "block body is not a JSON array"} | drops]}

      {:error, %Jason.DecodeError{} = err} ->
        {intents, [%{raw: body, reason: "JSON parse error: #{Exception.message(err)}"} | drops]}
    end
  end

  @doc """
  Validate a single intent map against an agent's `tool_policy`. Public for
  testability.
  """

  @spec validate(term(), map()) ::
          {:ok, map()} | {:error, String.t()} | {:error, {atom(), String.t()}}

  def validate(raw, tool_policy \\ %{})

  def validate(raw, tool_policy) when is_map(raw) and is_map(tool_policy) do
    case Map.get(raw, "kind") do
      "ui.request_approval" -> request_approval(raw, tool_policy)
      kind when is_binary(kind) -> Aqua.Intents.validate(raw)
      _ -> {:error, "missing or non-string 'kind'"}
    end
  end

  def validate(_, _), do: {:error, "entry is not an object"}

  defp request_approval(obj, tool_policy) do
    with {:ok, title} <- Aqua.Intents.string_field(obj, "title"),
         {:ok, summary} <- Aqua.Intents.string_field(obj, "summary"),
         {:ok, action_description} <- Aqua.Intents.string_field(obj, "action_description"),
         {:ok, hinted_risk} <- risk_field(obj),
         {:ok, proposal, action_kind, standing} <-
           validate_proposal(Map.get(obj, "proposal"), tool_policy) do
      {:ok,
       %{
         kind: "request_approval",
         id: Cyfr.UUID7.generate_id("apr"),
         title: title,
         summary: summary,
         # Risk derived from the action's `kind`, not from the policy mode
         # or the agent's hinted risk. Kind comes from the tool definition's
         # annotations (or AquaVirtualTools for `files`/`storage`/`http`).
         # Approval cards color themselves from this kind.
         action_kind: action_kind,
         # How far a standing answer may reach, from the same declaration:
         # `"conversation"`, `false`, or nil for either scope. Spelled as
         # it survives the row's JSON round trip, because the runner reads
         # it back from there.
         standing: Cyfr.Ops.Annotations.standing_to_wire(standing),
         hinted_risk: hinted_risk,
         action_description: action_description,
         proposal: proposal
       }}
    end
  end

  # Pure-confirmation card with no executable proposal. Used when the agent

  # wants explicit user buy-in before continuing freeform reasoning. Kind is

  # `nil` because no specific action is bound.

  defp validate_proposal(nil, _policy), do: {:ok, nil, nil, nil}

  defp validate_proposal(%{} = p, tool_policy) do
    with {:ok, tool} <- Aqua.Intents.string_field(p, "tool"),
         :ok <- Aqua.Intents.check_id_shape(tool, "ui.request_approval.proposal", "tool"),
         {:ok, action} <- Aqua.Intents.string_field(p, "action"),
         :ok <- Aqua.Intents.check_id_shape(action, "ui.request_approval.proposal", "action"),
         args <- Map.get(p, "args", %{}),
         :ok <- ensure_object(args, "ui.request_approval.proposal.args"),
         {:ok, %{tool: tool, action: action, args: args}} <-
           canonical_proposal(tool, action, args, tool_policy),
         :ok <- lookup_proposal(tool_policy, tool, action) do
      {:ok, %{tool: tool, action: action, args: args}, Aqua.Kinds.kind_for(tool, action),
       Aqua.Kinds.standing_for(tool, action)}
    end
  end

  defp validate_proposal(_, _),
    do: {:error, "ui.request_approval: proposal must be an object when present"}

  # The operation a proposal IS, decided before its policy, its kind and

  # its scopes are — so a card is always for the canonical operation and

  # an `execution.run` spelling of a delete can never earn an execute-kind

  # card. Three cases: the AQUA formula itself is not a tool the model may

  # run; an `execution.run` of a wrapped catalyst is the virtual action its

  # input denotes (`Aqua.VirtualTools.canonical/2`); a `files` call whose

  # path lands in the storage boundary is the storage operation. A request

  # two virtual actions build identically is canonical only when the

  # policy answers the same for both.

  defp canonical_proposal("execution", action, %{"reference" => reference} = args, policy)
       when action in ["run", "run_stream"] and is_binary(reference) do
    cond do
      Aqua.VirtualTools.self_reference?(reference) ->
        {:error,
         {:not_in_allowlist,
          "ui.request_approval: the assistant itself is not a tool to run — clone a role instead"}}

      true ->
        case Aqua.VirtualTools.canonical(reference, Map.get(args, "input") || %{}) do
          {:ok, candidates} ->
            pick_canonical(candidates, policy, reference)

          {:error, :not_virtual} ->
            {:ok, %{tool: "execution", action: action, args: args}}

          {:error, :unknown_operation} ->
            {:error,
             {:not_in_allowlist,
              "ui.request_approval: execution of #{reference} names no operation this " <>
                "assistant has — propose the files, storage or http action itself"}}
        end
    end
  end

  defp canonical_proposal("files", action, args, _policy) do
    case Aqua.VirtualTools.canonical_files(action, args) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, :not_a_storage_operation} ->
        {:error,
         {:not_in_allowlist,
          "ui.request_approval: files.#{action} inside data/storage/ is not a storage " <>
            "operation — use the storage tool"}}

      {:error, :unknown_operation} ->
        {:ok, %{tool: "files", action: action, args: args}}
    end
  end

  defp canonical_proposal(tool, action, args, _policy),
    do: {:ok, %{tool: tool, action: action, args: args}}

  defp pick_canonical([first | _] = candidates, policy, reference) do
    values = Enum.map(candidates, &policy_value(policy, &1.tool, &1.action))

    if Enum.uniq(values) |> length() == 1 do
      {:ok, first}
    else
      {:error,
       {:not_in_allowlist,
        "ui.request_approval: execution of #{reference} could be " <>
          Enum.map_join(candidates, " or ", &"#{&1.tool}.#{&1.action}") <>
          ", which your policy answers differently — propose the action itself"}}
    end
  end

  # Allowlist values: "ask" (request approval) | "auto" (call directly). An

  # absent key (and no matching `tool.*` glob) means the agent cannot perform

  # the action at all. Only "ask" should result in a proposal flowing to the

  # user; the others are validation errors at this stage. Policy refusals

  # carry a typed tag alongside the prose — the tripwire surface decides on

  # the tag, never by matching the wording.

  defp lookup_proposal(policy, tool, action) do
    key = "#{tool}.#{action}"

    case policy_value(policy, tool, action) do
      "ask" ->
        # The harness runs an approved proposal inside the chain, so an
        # action that plane refuses would become a card that fails on the
        # click. Say so here instead, where the agent can act on it. A UI
        # event the guest answers in place is never a card either.
        cond do
          Aqua.VirtualTools.auto_only?(tool, action) ->
            {:error,
             {:auto_allowlisted,
              "ui.request_approval: '#{key}' runs on its own — call it directly, do not request approval"}}

          Aqua.Kinds.refused?(tool, action) ->
            {:error,
             {:chat_refused,
              "ui.request_approval: '#{key}' cannot be run from a chat — tell the person to " <>
                "open its page"}}

          true ->
            :ok
        end

      # A standing "never": the composition keeps the pair as an exact
      # key so no glob can answer for it. Not proposable, and said so.
      "deny" ->
        {:error,
         {:not_in_allowlist,
          "ui.request_approval: '#{key}' was declined for good — it is not available"}}

      "auto" ->
        {:error,
         {:auto_allowlisted,
          "ui.request_approval: '#{key}' is allowlisted as 'auto' — call it directly, do not request approval"}}

      nil ->
        {:error,
         {:not_in_allowlist, "ui.request_approval: '#{key}' is not in your tool allowlist"}}

      other ->
        {:error,
         {:unknown_allowlist_value,
          "ui.request_approval: '#{key}' has unknown allowlist value #{inspect(other)}"}}
    end
  end

  # Resolve the allowlist value for `tool.action`, falling back to a `tool.*`

  # glob over all of that tool's actions.

  defp policy_value(policy, tool, action) when is_map(policy) do
    Map.get(policy, "#{tool}.#{action}") || Map.get(policy, "#{tool}.*")
  end

  defp ensure_object(value, _label) when is_map(value), do: :ok

  defp ensure_object(_, label), do: {:error, "#{label}: must be a JSON object"}

  defp risk_field(obj) do
    case Map.get(obj, "risk") do
      v when is_binary(v) and v in @allowed_risks ->
        {:ok, v}

      other ->
        {:error, "ui.request_approval: risk must be low|medium|high, got #{inspect(other)}"}
    end
  end
end
