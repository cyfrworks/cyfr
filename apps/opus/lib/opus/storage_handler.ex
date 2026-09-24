# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StorageHandler do
  @moduledoc """
  The `cyfr:storage/files@0.1.0` host import: a catalyst's storage
  operations, run by CYFR through the attempt's host client.

  A guest's request is a JSON string:

      {"action": "read", "path": "data/file.txt"}
      {"action": "write", "path": "data/file.txt", "content": "<base64>"}
      {"action": "append", "path": "data/file.txt", "content": "<base64>"}
      {"action": "list", "path": "data/"}
      {"action": "delete", "path": "data/file.txt"}
      {"action": "exists", "path": "data/file.txt"}

  `list` and `exists` without a path name the scope listing (`""`).

  The import bounds the raw request by the node's limits
  (`Opus.EdgeGuard.check_envelope_size/2`), parses it, and asks CYFR to run
  the operation (`Opus.HostClient.storage/3`). What the operation may reach
  — the consented actions and paths, the guest scopes, the size limits and
  the quotas — is decided by CYFR (`c:Prima.HostAPI.storage/3`), which runs
  it only while the attempt still holds its row.

  ## Answers

  On success, `"status": "ok"` with the members CYFR answered:

      {"status": "ok", "path": "...", "content": "<base64>", "size": 123, "encoding": "base64"}
      {"status": "ok", "path": "...", "written": true, "size": 123}
      {"status": "ok", "path": "...", "appended": true, "size": 123}
      {"status": "ok", "path": "...", "files": [...]}
      {"status": "ok", "path": "...", "deleted": true}
      {"status": "ok", "path": "...", "exists": true}

  On a refusal, `{"error": {"type": "...", "message": "..."}}`: CYFR's own
  refusal; `request_too_large` for a request past the envelope bound;
  `invalid_json`, `invalid_request` or `unknown_action` for one that does
  not parse; `storage_error` when the attempt no longer holds its row or
  CYFR's store cannot answer; and `storage_uncertain` when CYFR ran the
  operation and its answer was lost, since the write may be at the path.
  Every refusal but `storage_uncertain` wrote nothing.

  Each call fires `[:cyfr, :opus, :storage, :call]`
  (`Opus.Telemetry.storage_call/4`).
  """

  alias Prima.Limits
  alias Opus.{EdgeGuard, HostClient}

  @actions %{
    "read" => :read,
    "write" => :write,
    "append" => :append,
    "list" => :list,
    "delete" => :delete,
    "exists" => :exists
  }

  @doc """
  The import map for `cyfr:storage/files@0.1.0`: its `call` function runs
  `execute/4` with the node's `limits`, the attempt's host client `host`
  and the component reference its telemetry names.
  """
  @spec build_storage_imports(Limits.t() | nil, HostClient.t(), String.t()) :: map()
  def build_storage_imports(limits, %HostClient{} = host, component_ref) do
    %{
      "cyfr:storage/files@0.1.0" => %{
        "call" => {:fn, fn json_request -> execute(json_request, limits, host, component_ref) end}
      }
    }
  end

  @doc "Run one guest storage request, answering the JSON the guest's `call` returns."
  @spec execute(String.t(), Limits.t() | nil, HostClient.t(), String.t()) :: String.t()
  def execute(json_request, limits, %HostClient{} = host, component_ref)
      when is_binary(json_request) do
    started = System.monotonic_time(:millisecond)
    {action, result} = requested(json_request, limits, host)

    Opus.Telemetry.storage_call(
      component_ref,
      action,
      if(match?({:ok, _}, result), do: :ok, else: :error),
      System.monotonic_time(:millisecond) - started
    )

    encode(result)
  end

  defp requested(json_request, limits, host) do
    with :ok <- envelope(json_request, limits),
         {:ok, op, args} <- parse(json_request) do
      {Atom.to_string(op), stored(host, op, args)}
    else
      {:error, _type, _message} = refused -> {"unknown", refused}
    end
  end

  defp envelope(json_request, %Limits{} = limits) do
    case EdgeGuard.check_envelope_size(limits, json_request) do
      :ok ->
        :ok

      {:error, :request_too_large} ->
        {:error, :request_too_large,
         "Request exceeds the consented max_request_size for this component."}
    end
  end

  defp envelope(_json_request, nil), do: :ok

  defp parse(json_request) do
    case Jason.decode(json_request) do
      {:ok, %{"action" => action} = request} when is_binary(action) ->
        with {:ok, op} <- action(action),
             {:ok, path} <- path(op, action, request),
             {:ok, content} <- content(request) do
          args = if is_nil(content), do: %{}, else: %{"content" => content}
          {:ok, op, Map.put(args, "path", path)}
        end

      {:ok, _other} ->
        {:error, :invalid_request, "Request must include 'action' (string)"}

      {:error, _reason} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  defp action(action) do
    case Map.fetch(@actions, action) do
      {:ok, op} ->
        {:ok, op}

      :error ->
        {:error, :unknown_action,
         "Unknown storage action: #{action}. Use: read, write, append, list, delete, or exists"}
    end
  end

  defp path(op, action, request) do
    case Map.get(request, "path") do
      path when is_binary(path) ->
        {:ok, path}

      nil when op in [:list, :exists] ->
        {:ok, ""}

      _other ->
        {:error, :invalid_request, "Request must include 'path' (string) for action '#{action}'"}
    end
  end

  defp content(%{"content" => content}) when not is_nil(content) and not is_binary(content),
    do: {:error, :invalid_request, "'content' must be a base64 string."}

  defp content(request), do: {:ok, Map.get(request, "content")}

  defp stored(host, op, args) do
    case HostClient.storage(host, op, args) do
      {:ok, members} ->
        {:ok, members}

      {:error, {:guest_error, type, message}} ->
        {:error, type, message}

      {:error, :unavailable} ->
        {:error, :storage_error, "Storage refused: the execution store is unavailable."}

      # CYFR ran the operation and its answer did not come back, so what
      # the store holds is unknown. A write may be at the path: the guest
      # is never told it failed, and the sentence says what to do about it
      # — the same contract `storage_uncertain` carries from CYFR.
      {:error, {:uncertain, sentence}} ->
        {:error, :storage_uncertain, sentence <> " — read the path back before writing it again."}

      {:error, _lost} ->
        {:error, :storage_error, "Storage refused: the execution attempt is not current."}
    end
  end

  defp encode({:ok, members}), do: Prima.WitResponse.safe_encode(Map.put(members, "status", "ok"))
  defp encode({:error, type, message}), do: Prima.WitResponse.encode_error(type, message)
end
