# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClient do
  @moduledoc """
  A runner's client of CYFR's host calls (`Cyfr.HostAPI`), for one
  execution attempt.

  A client names the attempt (its athanor, execution, attempt id, fence and
  generation), the runner presenting it and the attempt key CYFR issued
  with the assignment. Every call is a JSON body, `{"op": name,
  "args": {...}}`, signed with the attempt key under a fresh nonce and the
  current time (`Cyfr.WorkerAuth.host_call_header/3`), and its answer is
  JSON. `transport/2` carries the header and body to CYFR and brings the
  answer back; nothing but those strings crosses it.

  Each function answers as the `Cyfr.HostAPI` callback of the same name.
  An answer that cannot be read is `{:error, :lost}`.
  """

  alias Cyfr.WorkerAuth

  @enforce_keys [:athanor_id, :execution_id, :attempt, :fence, :generation, :runner, :key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          runner: String.t(),
          key: binary()
        }

  @refusals %{
    "lost" => :lost,
    "unavailable" => :unavailable,
    "replayed" => :replayed,
    "malformed" => :malformed,
    "bad_mac" => :bad_mac,
    "unknown_version" => :unknown_version,
    "claim_expired" => :claim_expired
  }

  @doc """
  A client for `attempt` (`t:Cyfr.WorkerAuth.attempt/0`), signing with
  `key`. `runner` names the runner presenting the calls; a fresh runner id
  is minted when it is absent.
  """
  @spec new(Cyfr.WorkerAuth.attempt(), binary(), String.t() | nil) :: t()
  def new(attempt, key, runner \\ nil) when is_map(attempt) and is_binary(key) do
    %__MODULE__{
      athanor_id: Map.fetch!(attempt, :athanor_id),
      execution_id: Map.fetch!(attempt, :execution_id),
      attempt: Map.fetch!(attempt, :attempt),
      fence: Map.fetch!(attempt, :fence),
      generation: Map.fetch!(attempt, :generation),
      runner: runner || Cyfr.UUID7.generate_id("runner"),
      key: key
    }
  end

  @doc "Attach with the assignment `token`, answering the run's vault fields."
  @spec attach(t(), String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def attach(%__MODULE__{} = client, token) when is_binary(token) do
    with {:ok, %{} = secrets} <- request(client, "attach", %{"assignment" => token}),
         do: {:ok, secrets}
  end

  @doc "Renew the leases of `attempts`, answering each one's renewal by attempt id."
  @spec renew(t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => Cyfr.HostAPI.renewal()}} | {:error, term()}
  def renew(%__MODULE__{} = client, attempts) when is_list(attempts) do
    with {:ok, %{} = renewals} <- request(client, "renew", %{"attempts" => attempts}) do
      {:ok, Map.new(renewals, fn {attempt, renewal} -> {attempt, renewal(renewal)} end)}
    end
  end

  @doc "Close the attempt completed with the guest's `output`, answering the output as recorded."
  @spec complete(t(), term()) :: {:ok, term()} | {:error, term()}
  def complete(%__MODULE__{} = client, output) do
    request(client, "complete", %{
      "outcome" => outcome(client, "completed", %{"output" => output})
    })
  end

  @doc "Close the attempt failed with the sentence `error`."
  @spec fail(t(), String.t()) :: :ok | {:error, term()}
  def fail(%__MODULE__{} = client, error) when is_binary(error) do
    case request(client, "fail", %{"outcome" => outcome(client, "failed", %{"error" => error})}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deliver the guest's emitted JSON `events`, in order, answering one reply per event."
  @spec push_deltas(t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def push_deltas(%__MODULE__{} = client, events) when is_list(events) do
    deltas =
      for event <- events do
        %{
          "execution_id" => client.execution_id,
          "attempt" => client.attempt,
          "fence" => client.fence,
          "event" => event
        }
      end

    with {:ok, replies} when is_list(replies) and length(replies) == length(events) <-
           request(client, "push_deltas", %{"deltas" => deltas}) do
      if Enum.all?(replies, &is_binary/1), do: {:ok, replies}, else: {:error, :lost}
    else
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Dispense an OAuth access token for `provider`."
  @spec oauth_token(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def oauth_token(%__MODULE__{} = client, provider) when is_binary(provider) do
    case request(client, "oauth_token", %{"provider" => provider}) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Take one request from the consented rate for `bucket`."
  @spec take_rate(t(), String.t()) :: :ok | {:error, term()}
  def take_rate(%__MODULE__{} = client, bucket) when is_binary(bucket) do
    case request(client, "take_rate", %{"bucket" => bucket}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Carry one signed host call to CYFR: the header and the JSON body it
  signs, answered with CYFR's JSON.
  """
  @spec transport(String.t(), String.t()) :: String.t()
  def transport(header, body) when is_binary(header) and is_binary(body),
    do: Cyfr.Execution.Host.call(header, body)

  defp request(client, op, args) do
    with {:ok, body} <- Jason.encode(%{"op" => op, "args" => args}),
         {:ok, header} <- WorkerAuth.host_call_header(client.key, call_fields(client), body) do
      header |> transport(body) |> answer()
    else
      _ -> {:error, :lost}
    end
  end

  defp call_fields(client) do
    %{
      athanor_id: client.athanor_id,
      execution_id: client.execution_id,
      attempt: client.attempt,
      fence: client.fence,
      generation: client.generation,
      runner: client.runner,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }
  end

  defp outcome(client, status, fields) do
    Map.merge(fields, %{
      "execution_id" => client.execution_id,
      "attempt" => client.attempt,
      "fence" => client.fence,
      "status" => status
    })
  end

  defp answer(json) do
    case Jason.decode(json) do
      {:ok, %{"ok" => value}} ->
        {:ok, value}

      {:ok, %{"error" => "setup_required", "payload" => %{} = payload}} ->
        {:error, {:setup_required, payload}}

      {:ok, %{"error" => "guest_error", "type" => type, "message" => message}}
      when is_binary(type) and is_binary(message) ->
        {:error, {:guest_error, type, message}}

      {:ok, %{"error" => "failed", "message" => message}} when is_binary(message) ->
        {:error, {:failed, message}}

      {:ok, %{"error" => refusal}} when is_map_key(@refusals, refusal) ->
        {:error, Map.fetch!(@refusals, refusal)}

      _ ->
        {:error, :lost}
    end
  end

  defp renewal(%{"lease_until" => until}) when is_integer(until), do: {:ok, until}
  defp renewal("cancel"), do: :cancel
  defp renewal(_lost), do: :lost
end
