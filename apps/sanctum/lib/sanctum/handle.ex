# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Handle do
  @moduledoc """
  A handle at the registry, resolved to the identifier it names
  (`Prima.HandleAnswer`, `cyfr-handle/v1`), and that account's keys read
  from the directory the answer names.

  The registry's answer is navigation, never authority: it names an
  identifier and the directory that orders it, and carries no keys and no
  address. `resolve/1` then reads the account's log at that directory
  (`Sanctum.IdentityFreshness.fresh!/2`, which verifies it and caches its
  head), so a handle the registry later reassigns moves no access, and an
  account its directory answers gone resolves to nothing, as no holder
  does: the registry keeps a gone account's name reserved, and it names
  no one who can sign.

  `resolve/1` asks `GET /v1/handles/{handle}` of the registry this
  deployment names (`Sanctum.registry_host/0`), for that one exact handle:
  there is no listing or search. `name_of/1` asks the reverse,
  `GET /v1/identities/{identifier}/handle`, for the one name an identifier
  holds, so a sign-in learns the account's name without the person typing
  it; it reads no log, since its caller has just verified the account's
  keys. The request goes through
  `Sanctum.Egress.pinned_request/5` under `private_policy: :operator`, is
  bounded to 10 seconds and 16 KiB, follows no redirect, sends no
  credential, and the answer is not cached.

  A registry this node serves, where it is its account service's writer
  (`Sanctum.Directory.writer?/0`) and the registry it names is its own
  origin, scheme and port as well as host, is read where it is kept (`Sanctum.Directory.Handles`),
  never over HTTP to this node, as the directory's own client reads the
  logs it serves: its listener need not answer on the address its origin
  names. Its answers are the routes' own, so both lookups answer the same
  either way.

  Refusals: `:invalid_handle` (a spelling `Prima.ComponentRef` refuses as
  a personal slug, before any request), `:not_found` (no one holds the
  handle, a reserved one
  included, or its account is gone), `:registry_unavailable` (the
  registry or the directory it names unreachable, slow, refused by the
  address policy, a log that does not verify, or any answer but the ones
  above) and `:malformed_answer` (an answer for another handle or
  registry, or outside its grammar).
  """

  require Logger

  alias Prima.HandleAnswer

  @request_ms 10_000
  @response_bytes 16_384

  @type reason ::
          :invalid_handle | :not_found | :registry_unavailable | :malformed_answer

  @doc "Resolve `handle` at this deployment's registry (the module doc)."
  @spec resolve(String.t()) :: {:ok, HandleAnswer.t()} | {:error, reason()}
  def resolve(handle) when is_binary(handle) do
    with :ok <- spelled(handle),
         {:ok, answer} <- asked(Sanctum.registry_host(), handle) do
      keys(answer)
    end
  end

  def resolve(_handle), do: {:error, :invalid_handle}

  @doc """
  The name `identifier` holds at this deployment's registry (the module
  doc): `cyfr-handle/v1` for that identifier, or `:not_found` when it holds
  none. Refusals: `:invalid_identifier` (before any request),
  `:not_found`, `:registry_unavailable` and
  `:malformed_answer` (an answer for another identifier or registry, or
  outside its grammar).
  """
  @spec name_of(String.t()) :: {:ok, HandleAnswer.t()} | {:error, reason() | :invalid_identifier}
  def name_of(identifier) when is_binary(identifier) do
    with :ok <- identifier_spelled(identifier) do
      registry = Sanctum.registry_host()

      if served_here?() do
        identifier |> Sanctum.Directory.Handles.held() |> kept()
      else
        url =
          Sanctum.registry_base_url(Sanctum.registry_url()) <>
            "/v1/identities/" <> identifier <> "/handle"

        url |> fetch() |> name_answer(identifier, registry)
      end
    end
  end

  def name_of(_identifier), do: {:error, :invalid_identifier}

  @doc """
  The identifier `handle` names, for a write that keeps the identifier and
  never the handle (an allowlist entry, a membership): `resolve/1`, its
  refusals as the writer answers them. A spelling the slug grammar refuses
  is an invalid argument that says what a handle is; no one holding the
  handle is `:handle_not_found`; an unreadable answer is
  `:registry_unavailable`, as an unreachable registry is. It writes
  nothing but this home's cache of the account's head, so a caller that
  resolves first and writes after leaves no row of its own when it stops
  between the two.
  """
  @spec identifier(String.t()) ::
          {:ok, String.t()}
          | {:error,
             {:invalid_argument, String.t()}
             | :handle_not_found
             | :registry_unavailable}
  def identifier(handle) do
    case resolve(handle) do
      {:ok, %HandleAnswer{identifier: identifier}} ->
        {:ok, identifier}

      {:error, :invalid_handle} ->
        {:error,
         {:invalid_argument,
          "That is not a handle: a handle is lowercase letters, digits and single hyphens, " <>
            "at most 39 characters"}}

      {:error, :not_found} ->
        {:error, :handle_not_found}

      {:error, :malformed_answer} ->
        {:error, :registry_unavailable}

      {:error, :registry_unavailable} ->
        {:error, :registry_unavailable}
    end
  end

  # The handle's answer, from the registry this node serves where it is
  # kept, or over the wire.
  defp asked(registry, handle) do
    if served_here?() do
      handle |> Sanctum.Directory.Handles.holder() |> kept()
    else
      url =
        Sanctum.registry_base_url(Sanctum.registry_url()) <>
          "/v1/handles/" <> URI.encode(handle, &URI.char_unreserved?/1)

      url |> fetch() |> answer(handle, registry)
    end
  end

  # Whether the registry this deployment names is the origin this node
  # serves as its account service's writer: the registry's endpoint, as
  # requests to it are sent, and this node's origin, each in the one
  # spelling a home has (`Sanctum.Directory.served/0`), scheme and port
  # kept and only a scheme's default port dropped. Another port, another
  # scheme or a path is another registry, asked over the wire.
  defp served_here? do
    endpoint = Sanctum.registry_base_url(Sanctum.registry_url())

    with true <- Sanctum.Directory.writer?(),
         {:ok, served} <- Sanctum.Directory.served() do
      Prima.Identity.Encoding.canonical_home(endpoint) == {:ok, served}
    else
      _elsewhere -> false
    end
  end

  # A served read's refusal, as the wire's would read: no one's name, or a
  # registry that cannot answer.
  defp kept({:ok, %HandleAnswer{} = answer}), do: {:ok, answer}
  defp kept({:error, :handle_not_found}), do: {:error, :not_found}
  defp kept({:error, _unanswered}), do: {:error, :registry_unavailable}

  # The account the answer names, read at its directory: one gone there
  # has no holder.
  defp keys(%HandleAnswer{identifier: identifier, directory: directory} = answer) do
    case Sanctum.IdentityFreshness.fresh!(identifier, directory: directory) do
      {:ok, _head} ->
        {:ok, answer}

      {:refused, :identity_gone} ->
        {:error, :not_found}

      {:refused, :identity_stale} ->
        {:error, :registry_unavailable}

      {:error, :unavailable} ->
        {:error, :registry_unavailable}
    end
  end

  defp identifier_spelled(identifier) do
    if Prima.Identity.Encoding.identifier?(identifier),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp spelled(handle) do
    if Prima.ComponentRef.valid_personal_slug?(handle),
      do: :ok,
      else: {:error, :invalid_handle}
  end

  # The request runs in a task linked to the caller, so it stops with the
  # caller, and the yield bounds it even against a registry that answers a
  # byte at a time.
  defp fetch(url) do
    task =
      Task.Supervisor.async(Sanctum.TaskSupervisor, fn ->
        try do
          Sanctum.Egress.pinned_request(
            :get,
            url,
            [{"accept", "application/json"}, {"user-agent", "CYFR/" <> Prima.Version.current()}],
            nil,
            private_policy: :operator,
            receive_timeout: @request_ms,
            max_response_bytes: @response_bytes
          )
        rescue
          exception -> {:error, {:raised, exception.__struct__}}
        end
      end)

    case Task.yield(task, @request_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out -> {:error, :timeout}
    end
  end

  defp answer({:ok, 200, _headers, body}, handle, registry) do
    case HandleAnswer.parse(body, handle, registry) do
      {:ok, answer} -> {:ok, answer}
      {:error, :handle_not_found} -> {:error, :not_found}
      {:error, _malformed} -> {:error, :malformed_answer}
    end
  end

  defp answer({:ok, 404, _headers, _body}, _handle, _registry), do: {:error, :not_found}

  defp answer({:ok, status, _headers, _body}, _handle, _registry) do
    Logger.warning("[Sanctum.Handle] the registry answered a handle with HTTP #{status}")
    {:error, :registry_unavailable}
  end

  defp answer({:error, reason}, _handle, _registry) do
    Logger.warning(
      "[Sanctum.Handle] a handle request failed: " <> Prima.LoggerContext.shape(reason)
    )

    {:error, :registry_unavailable}
  end

  # The reverse answer names the handle itself; it is parsed as the answer
  # for that handle and must name the identifier asked.
  defp name_answer({:ok, 200, _headers, body}, identifier, registry) do
    case Prima.Json.decode(body) do
      {:ok, %{"handle" => handle} = map} when is_binary(handle) ->
        case HandleAnswer.parse(map, handle, registry) do
          {:ok, %HandleAnswer{identifier: ^identifier} = answer} -> {:ok, answer}
          {:ok, %HandleAnswer{}} -> {:error, :malformed_answer}
          {:error, :handle_not_found} -> {:error, :not_found}
          {:error, _malformed} -> {:error, :malformed_answer}
        end

      {:ok, %{"errors" => _} = envelope} ->
        case HandleAnswer.parse(envelope, "", registry) do
          {:error, :handle_not_found} -> {:error, :not_found}
          _ -> {:error, :malformed_answer}
        end

      _ ->
        {:error, :malformed_answer}
    end
  end

  defp name_answer(other, _identifier, registry), do: answer(other, nil, registry)
end
