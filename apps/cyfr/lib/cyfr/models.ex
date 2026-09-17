# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Models do
  @moduledoc """
  The host side of `model/chat@1`, the contract a model catalyst declares
  in its manifest (`"contracts": ["model/chat@1"]`) and answers on its one
  `run` export as three operations of the catalyst envelope
  (`{"operation", "params"}` in, `{"status", "data" | "error"}` out):

    * `chat` — a contract request in, a contract response out. Request:
      `model`, `system?`, `messages` (`user`/`assistant`/`tool` roles;
      content a string or typed blocks: `text`, `image`, `document`,
      `tool_call {id, name, arguments, provider_data?}`, `tool_result
      {tool_call_id, name, content, is_error?}`), `tools?` (`name`,
      `description`, `parameters`), `provider_tools?` (names the catalyst
      offers, e.g. `web_search`), `max_tokens?`, `temperature?`. Response:
      `model`, `content` (`text` and `tool_call` blocks), `stop_reason`
      (`end_turn | tool_call | max_tokens | content_filter | other`),
      `usage` (`input_tokens`, `output_tokens`, `cache_read_tokens`,
      `cache_write_tokens`).
    * `describe` — what the catalyst can do, answered without a key:
      `contracts`, `provider`, `tools`, `provider_tools`, `media_types`,
      `streaming`, `defaults`. With `{"model": id}` it adds that model's
      `context_window` and `max_output_tokens` (from the provider's models
      API where it reports them, which may take the key), and
      `max_input_tokens` where the provider bounds the input on its own,
      or refuses a model the catalyst does not know as `unknown_model`.
    * `models` — what the bound key can reach: `models` as `{id, name,
      context_window?, max_output_tokens?}`.

  While `chat` runs, the catalyst streams the answer on its execution's
  event stream (`cyfr:emit/events`): `text.delta {text}`,
  `tool_call.start {index, id, name}`, `tool_call.delta {index,
  arguments}`, `tool_call.end {index}`, `usage {usage}`, `stop
  {stop_reason}`, `error {error}` — and still answers the whole response.

  A refusal is `{"status": N, "error": {"type", "message", "provider"?}}`
  with `type` one of `invalid_request`, `secret_denied`, `authentication`,
  `rate_limited`, `overloaded`, `provider_error`, `incomplete_stream` (the
  provider's stream ended before its closing signal), `unknown_model`,
  `unknown_operation`.
  The provider's HTTP call and the key stay in the catalyst; this module
  only names the contract, reads the envelope, and runs the listing the
  console shows.
  """

  alias Sanctum.Context

  @chat "model/chat@1"

  # A listing runs every contract catalyst the athanor holds; each is one
  # root execution and one provider round trip.
  @listing_concurrency 5
  @listing_timeout_ms 30_000
  @capabilities_ttl_ms :timer.hours(24)

  @typedoc """
  What a planner needs to size a request: the model's context window,
  its output ceiling and its input ceiling where the provider bounds the
  input on its own, the provider tools and media types the catalyst
  offers, whether it streams, and its default `max_tokens`.

  Every limit is a positive integer or `nil`; a limit `describe` leaves
  out or answers as zero, negative or not an integer reads as `nil`,
  never as zero, so a malformed ceiling loosens nothing and tightens
  nothing. Only `context_window` is required: an input ceiling never
  stands in for the window.
  """
  @type capabilities :: %{
          context_window: pos_integer(),
          max_output_tokens: pos_integer() | nil,
          max_input_tokens: pos_integer() | nil,
          provider_tools: [String.t()],
          media_types: [String.t()],
          streaming: boolean(),
          default_max_tokens: pos_integer() | nil
        }

  @doc """
  The capabilities of `model` on `resolved_ref`: the catalyst's
  `describe` of that model, run through `run` — a function the caller
  supplies that runs one contract operation on the catalyst under the
  caller's own authority (`%{"operation" => op, "params" => params}` →
  `{:ok, result} | {:error, _}`), so a guest-planed loop reads through
  its pinned authority. Cached for a day under the resolved reference,
  the model and `binding_digest` (the key the reading ran with).

  Errors: `{:unknown_model, model}` when the catalyst does not know the
  model; `{:model_refused, error}` for any other typed refusal (the
  error map, e.g. `secret_denied` when describing the model takes a key
  that is not bound); `{:no_context_window, model}` when the answer
  names no window; `{:describe_failed, reason}` when the run failed.
  """
  @spec capabilities(Context.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, capabilities()} | {:error, term()}
  def capabilities(%Context{} = ctx, resolved_ref, model, binding_digest, opts)
      when is_binary(model) do
    run = Keyword.fetch!(opts, :run)
    key = {:model_caps, Context.athanor!(ctx), resolved_ref, model, binding_digest}

    case Arca.Cache.get(key) do
      {:ok, caps} ->
        {:ok, caps}

      :miss ->
        with {:ok, caps} <- describe_model(model, run) do
          Arca.Cache.put(key, caps, @capabilities_ttl_ms)
          {:ok, caps}
        end
    end
  end

  defp describe_model(model, run) do
    with {:ok, result} <- ran(run.(%{"operation" => "describe", "params" => %{"model" => model}})),
         {:ok, described} <- described(decode_envelope(result), model),
         {:ok, window} <- window(described, model) do
      {:ok,
       %{
         context_window: window,
         max_output_tokens: positive(described["max_output_tokens"]),
         max_input_tokens: positive(described["max_input_tokens"]),
         provider_tools: list_of_strings(described["provider_tools"]),
         media_types: list_of_strings(described["media_types"]),
         streaming: described["streaming"] == true,
         default_max_tokens: positive(get_in(described, ["defaults", "max_tokens"]))
       }}
    end
  end

  defp ran({:ok, result}), do: {:ok, result}
  defp ran({:error, reason}), do: {:error, {:describe_failed, reason}}

  defp described({:ok, data}, _model), do: {:ok, data}

  defp described({:error, %{"type" => "unknown_model"}}, model),
    do: {:error, {:unknown_model, model}}

  defp described({:error, error}, _model), do: {:error, {:model_refused, error}}

  # The window is the one limit a planner cannot do without: an answer
  # that bounds the input but names no window is refused, not sized from
  # the ceiling, because the ceiling says nothing about the output's share.
  defp window(described, model) do
    case positive(described["context_window"]) do
      nil -> {:error, {:no_context_window, model}}
      window -> {:ok, window}
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp list_of_strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp list_of_strings(_), do: []

  @doc "The chat contract's name, as a manifest declares it."
  @spec chat_contract() :: String.t()
  def chat_contract, do: @chat

  @doc "Whether a manifest declares the chat contract."
  @spec speaks_chat?(map() | nil | binary()) :: boolean()
  def speaks_chat?(manifest) do
    @chat in Compendium.Manifest.contracts(Cyfr.Manifest.decode(manifest))
  end

  @doc """
  The catalyst envelope an `execution.run` answered, read: `{:ok, data}`
  for a 2xx `data`, `{:error, %{"type" => _, "message" => _}}` for a
  refusal, and `{:error, %{"type" => "malformed"}}` for anything that is
  not the envelope. Accepts the run result (`%{result: envelope}`) or the
  envelope itself, as a map or JSON.
  """
  @spec decode_envelope(term()) :: {:ok, map()} | {:error, map()}
  def decode_envelope(%{result: envelope}), do: decode_envelope(envelope)
  def decode_envelope(%{"result" => envelope}), do: decode_envelope(envelope)

  def decode_envelope(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decode_envelope(decoded)
      _ -> {:error, %{"type" => "malformed", "message" => "the catalyst answered no envelope"}}
    end
  end

  def decode_envelope(%{"status" => status, "data" => data} = envelope)
      when is_integer(status) and status >= 200 and status < 300 do
    case envelope do
      %{"error" => _} -> {:error, malformed(envelope)}
      _ when is_map(data) -> {:ok, data}
      _ -> {:error, malformed(envelope)}
    end
  end

  def decode_envelope(%{"error" => %{"type" => type, "message" => message} = error})
      when is_binary(type) and is_binary(message),
      do: {:error, error}

  def decode_envelope(%{"error" => other}) do
    message = if is_binary(other), do: other, else: inspect(other)
    {:error, %{"type" => "provider_error", "message" => message}}
  end

  def decode_envelope(other), do: {:error, malformed(other)}

  defp malformed(envelope) do
    %{
      "type" => "malformed",
      "message" =>
        "the catalyst answered something that is not the envelope: " <>
          String.slice(inspect(envelope), 0, 200)
    }
  end

  @doc """
  The model listing the console shows: every installed catalyst that
  declares the contract, at its newest version, asked for `models`
  through the catalog (so consent applies: a catalyst with no key answers
  `setup_required` and is listed under `errors`, not `models`).

  Returns `{:ok, %{"models" => %{provider => [id]}, "refs" => %{provider
  => versionless ref}, "errors" => %{provider => message}}}`. A provider
  is the catalyst's name, prefixed by its namespace when that is not the
  local one, so two catalysts never share a row.
  """
  @spec catalogue(Context.t()) :: {:ok, map()} | {:error, term()}
  def catalogue(%Context{} = ctx) do
    with {:ok, catalysts} <- contract_catalysts(ctx) do
      results =
        Aqua.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          catalysts,
          fn {provider, ref} -> {provider, ref, list_models(ctx, ref)} end,
          max_concurrency: @listing_concurrency,
          timeout: @listing_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip(catalysts)
        |> Enum.map(fn
          {{:ok, answered}, _} -> answered
          {{:exit, _}, {provider, ref}} -> {provider, ref, {:error, "the listing did not answer"}}
        end)

      {:ok,
       Enum.reduce(results, %{"models" => %{}, "refs" => %{}, "errors" => %{}}, fn
         {provider, ref, {:ok, ids}}, acc ->
           acc
           |> put_in(["models", provider], ids)
           |> put_in(["refs", provider], ref)

         {provider, ref, {:error, message}}, acc ->
           acc
           |> put_in(["refs", provider], ref)
           |> put_in(["errors", provider], message)
       end)}
    end
  end

  # The newest installed version of every catalyst declaring the contract,
  # as `{provider, versionless_ref}`.
  defp contract_catalysts(ctx) do
    case Cyfr.Ops.Catalog.call_external("component", ctx, %{
           "action" => "list",
           "type" => "catalyst"
         }) do
      {:ok, %{components: rows}} when is_list(rows) -> {:ok, newest_speaking(rows)}
      {:ok, %{"components" => rows}} when is_list(rows) -> {:ok, newest_speaking(rows)}
      {:ok, _} -> {:error, :catalyst_lookup_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp newest_speaking(rows) do
    rows
    |> Enum.filter(&speaks_chat?(field(&1, :manifest)))
    |> Enum.group_by(&{field(&1, :publisher), field(&1, :name)})
    |> Enum.map(fn {{publisher, name}, versions} ->
      newest = versions |> Compendium.Semver.sort_desc_by(&(field(&1, :version) || "0")) |> hd()
      {provider_key(publisher, name), Compendium.Activation.node_key(newest)}
    end)
    |> Enum.sort()
  end

  defp provider_key(publisher, name) do
    case Compendium.ComponentPath.normalize_publisher(publisher) do
      "local" -> name
      namespace -> "#{namespace}.#{name}"
    end
  end

  defp list_models(ctx, ref) do
    run =
      Cyfr.Ops.Catalog.call_external("execution", ctx, %{
        "action" => "run",
        "reference" => ref,
        "type" => "catalyst",
        "input" => %{"operation" => "models", "params" => %{}}
      })

    with {:ok, result} <- run,
         {:ok, %{"models" => models}} when is_list(models) <- decode_envelope(result) do
      {:ok,
       models
       |> Enum.map(&(is_map(&1) && &1["id"]))
       |> Enum.filter(&(is_binary(&1) and &1 != ""))}
    else
      {:ok, _other} -> {:error, "the catalyst answered no model list"}
      {:error, %{"message" => message}} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, refusal_text(reason)}
    end
  end

  defp refusal_text(reason) when is_binary(reason), do: reason

  defp refusal_text(reason) do
    Cyfr.Ops.Error.render(reason) || "the catalyst could not be run: #{inspect(reason)}"
  end

  defp field(row, key) when is_atom(key),
    do: Map.get(row, key) || Map.get(row, Atom.to_string(key))
end
