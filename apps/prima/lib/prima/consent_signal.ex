# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentSignal do
  @moduledoc """
  The five consent signals: `{tag, payload}` with a map payload, the shape
  the deciding owner produces and every surface reads.

  Four are remediation: `setup_required`, `consent_required`,
  `consent_conflict` and `restart_required` say what to grant, approve or
  run again. The fifth, `confirmation_required`, is neither a denial nor a
  remediation: the change stands and waits for the person's fresh
  confirmation. Its payload is the pending confirmation's `id`, `operation`
  and `expires_at`, and a payload without a non-empty string `id` is no
  signal. The `id` is the asking request's secret, answered to that
  request alone: the asking client repeats the change under it, and the
  person confirms the change, on any of their clients, by the record's
  public ref (`Prima.Confirmation.ref/1`), never by the `id`. So the
  signal's sentence names the change and never the `id`: a sentence is
  what logs, request-log rows and pages keep. The payload's keys are atoms
  as a producer builds it, or strings as it reads back from JSON, and one
  payload holds `id` under exactly one of the two: a payload naming it
  both ways is no signal, so no reader can check one id and act on
  another. Its `error.data`, answered to the asking request alone,
  carries those three fields alone, so nothing else a producer put in the
  payload reaches a wire.

  Each signal has a sentence, a refusal class (`Prima.Refusal`) and
  `error.data` shaped as `{"tag": ..., "payload": ...}`; the MCP wire
  answers each tag with its own -335xx code.

  The GUEST wire is not this: in-chain formula children keep the
  remediation object shape `Prima.Remediation` owns (component-guide
  documents it), and the tincture iframe bridge keeps its own protocol.
  """

  @remediation_tags [:setup_required, :consent_required, :consent_conflict, :restart_required]
  @tags @remediation_tags ++ [:confirmation_required]

  @type tag ::
          :setup_required
          | :consent_required
          | :consent_conflict
          | :restart_required
          | :confirmation_required

  @doc """
  Whether `{tag, payload}` is a consent signal: a remediation tag with a
  map payload, or `confirmation_required` with a map payload whose `id`
  is a non-empty string. Usable in guards.
  """
  defguard is_signal(tag, payload)
           when is_map(payload) and
                  (tag in @remediation_tags or
                     (tag == :confirmation_required and
                        ((is_map_key(payload, :id) and not is_map_key(payload, "id") and
                            is_binary(:erlang.map_get(:id, payload)) and
                            :erlang.map_get(:id, payload) != "") or
                           (is_map_key(payload, "id") and not is_map_key(payload, :id) and
                              is_binary(:erlang.map_get("id", payload)) and
                              :erlang.map_get("id", payload) != ""))))

  @doc "Whether a term is a consent signal (`is_signal/2`)."
  @spec signal?(term()) :: boolean()
  def signal?({tag, payload}) when is_signal(tag, payload), do: true
  def signal?(_), do: false

  @doc "The five tag atoms, for rosters and drift tests."
  @spec tags() :: [tag()]
  def tags, do: @tags

  @doc """
  The short human sentence for a signal — what a client that reads no
  `data` shows. The payload's detail is for clients that branch. A
  `confirmation_required` sentence names the change and never the
  confirmation's secret `id`, which only `data/1` carries.
  """
  @spec message({tag(), map()}) :: String.t()
  def message({:setup_required, payload}) do
    case payload do
      %{"need" => need, "node_ref" => ref} when is_binary(need) and is_binary(ref) ->
        "Setup required: #{ref} needs a vault entry for \"#{need}\" — grant it a profile first"

      %{"node_ref" => ref} when is_binary(ref) ->
        "Setup required: #{ref} is not ready — grant it a profile first"

      _ ->
        "Setup required: the component is not ready — grant it a profile first"
    end
  end

  def message({:consent_required, payload}) do
    case payload do
      %{"detail" => detail} when is_binary(detail) ->
        "Consent required: #{detail}"

      _ ->
        "Consent required: permissions changed since they were approved — review and re-grant"
    end
  end

  def message({:consent_conflict, _payload}),
    do: "Consent conflict: the consent changed while deciding — re-run the grant"

  def message({:restart_required, _payload}),
    do: "Approved — re-run the command to continue (the in-flight run was stopped)"

  def message({:confirmation_required, payload})
      when is_signal(:confirmation_required, payload) do
    confirmation = confirmation(payload)

    change =
      case confirmation["operation"] do
        operation when is_binary(operation) and operation != "" -> operation
        _ -> "this change"
      end

    "Confirmation required: #{change} needs a fresh confirmation — confirm it in Prism"
  end

  @doc ~S"""
  The `error.data` object: `{"tag": tag, "payload": payload}`. A
  `confirmation_required` payload is carried as its `id`, `operation` and
  `expires_at` alone, under string keys.
  """
  @spec data({tag(), map()}) :: map()
  def data({:confirmation_required, payload} = signal)
      when is_signal(:confirmation_required, payload),
      do: %{"tag" => "confirmation_required", "payload" => confirmation(elem(signal, 1))}

  def data({tag, payload}) when is_signal(tag, payload),
    do: %{"tag" => Atom.to_string(tag), "payload" => payload}

  # The confirmation's three fields, read under the one key form its `id`
  # uses (`is_signal/2` admits no payload that names it both ways), with
  # an absent field left out.
  defp confirmation(payload) do
    keys =
      if is_map_key(payload, :id),
        do: [:id, :operation, :expires_at],
        else: ~w(id operation expires_at)

    for key <- keys, (value = Map.get(payload, key)) not in [nil, ""], into: %{} do
      {to_string(key), value}
    end
  end
end
