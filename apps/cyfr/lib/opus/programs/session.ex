# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Session do
  @moduledoc """
  The session routes of `Prima.LocusBackends`, as a holder speaks them under
  the grant `Opus.Programs.hold/1` answered: `open/2`, `send/3`, `recv/4`
  and `close/2`.

  Each runs in the calling process, as one request of its own, apart from
  the box's serialized control channel: a `recv` that waits up to its
  `max_wait_ms` never delays a `send`, a `sync` or a lease renewal. Every
  request carries an `x-cyfr-auth` header signed with the grant's owner key
  over the exact body sent, with a fresh nonce and timestamp, and goes
  through `Sanctum.Egress.pinned_request/5` under the operator's private
  egress policy.

  Answers are the wire's (`Prima.LocusBackends.read_session_answer/2`).
  A refusal is `{:error, {:refused, code, boot}}` with the code a box
  answers it as (`Opus.Programs.Box.refusal_name/1`) and the service boot
  id the answer named; a service that cannot be reached
  `{:error, :backends_unavailable}`; an answer that does not read
  `{:error, {:unreadable, error}}`.
  """

  alias Prima.LocusBackends

  # The wait beyond a recv's own, for the round trip.
  @slack_ms 10_000
  @send_timeout_ms 30_000
  @open_timeout_ms 60_000

  @type grant :: Opus.Programs.Box.grant()
  @type refusal ::
          {:refused, atom(), String.t() | nil}
          | :backends_unavailable
          | {:unreadable, term()}
          | {:invalid, term()}

  @doc """
  Open a session of `program` for `key`: mode `:run` attaches to the key's
  running session or starts the program with `argv`; mode `:sign_in` runs
  its login command on a pseudo-terminal in the kept home `home_id`.
  """
  @spec open(grant(), %{
          required(:program) => String.t(),
          required(:key) => String.t(),
          optional(:home_id) => String.t() | nil,
          optional(:mode) => :run | :sign_in,
          optional(:argv) => [String.t()]
        }) ::
          {:ok, %{session: String.t(), resumed: boolean(), pty: boolean()}}
          | {:error, refusal()}
  def open(grant, params) do
    message =
      Map.merge(base(:open, grant), %{
        program: params.program,
        home_id: Map.get(params, :home_id),
        key: params.key,
        mode: Map.get(params, :mode, :run),
        argv: Map.get(params, :argv, [])
      })

    with {:ok, answer} <- post(grant, message, @open_timeout_ms) do
      {:ok, Map.take(answer, [:session, :resumed, :pty])}
    end
  end

  @doc "Write `lines` to the session's process; `:ended` once it no longer runs."
  @spec send(grant(), String.t(), [String.t()]) ::
          {:ok, :running | :ended} | {:error, refusal()}
  def send(grant, session, lines) when is_list(lines) do
    message = Map.merge(base(:send, grant), %{session: session, lines: lines})

    with {:ok, %{status: status}} <- post(grant, message, @send_timeout_ms),
         do: {:ok, status}
  end

  @doc """
  The lines past `after`, waiting up to `max_wait_ms` for one or the
  process's end; idempotent, so a lost answer is asked for again by the
  same `after`.
  """
  @spec recv(grant(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, %{lines: [LocusBackends.line()], dropped: non_neg_integer(), running: boolean()}}
          | {:error, refusal()}
  def recv(grant, session, after_seq, max_wait_ms) do
    max_wait_ms = min(max_wait_ms, LocusBackends.max_recv_wait_ms())

    message =
      Map.merge(base(:recv, grant), %{
        session: session,
        after: after_seq,
        max_wait_ms: max_wait_ms
      })

    post(grant, message, max_wait_ms + @slack_ms)
  end

  @doc "End the session's process."
  @spec close(grant(), String.t()) :: :ok | {:error, refusal()}
  def close(grant, session) do
    message = Map.put(base(:close, grant), :session, session)

    with {:ok, _closed} <- post(grant, message, @send_timeout_ms), do: :ok
  end

  defp base(type, grant),
    do: %{type: type, owner: %{athanor: grant.athanor, server: grant.server}, e: grant.epoch}

  defp post(grant, message, timeout_ms) do
    invoke = %{
      athanor: grant.athanor,
      server: grant.server,
      generation: grant.generation,
      epoch: grant.epoch,
      boot: grant.boot,
      ts: System.os_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    with {:ok, body} <- encode(message),
         {:ok, header} <- sign(grant, invoke, body) do
      headers = [{"content-type", "application/json"}, {LocusBackends.auth_header(), header}]

      opts = [
        receive_timeout: timeout_ms,
        private_policy: :operator,
        max_response_bytes: LocusBackends.max_session_bytes()
      ]

      case Sanctum.Egress.pinned_request(:post, grant.url, headers, body, opts) do
        {:ok, 200, _headers, resp_body} ->
          case LocusBackends.read_session_answer(message.type, resp_body) do
            {:ok, answer} -> {:ok, answer}
            {:error, error} -> {:error, {:unreadable, error}}
          end

        {:ok, status, resp_headers, resp_body} ->
          {:error, refusal(status, resp_headers, resp_body)}

        {:error, _reason} ->
          {:error, :backends_unavailable}
      end
    end
  end

  defp encode(message) do
    case LocusBackends.encode_session(message) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, {:invalid, error}}
    end
  end

  defp sign(grant, invoke, body) do
    case LocusBackends.invoke_header(grant.owner_key, invoke, body) do
      {:ok, header} -> {:ok, header}
      {:error, error} -> {:error, {:invalid, error}}
    end
  end

  defp refusal(401, headers, _body),
    do: {:refused, :backends_refused_signature, Opus.Programs.Box.boot_header(headers)}

  defp refusal(status, headers, body) do
    with {:ok, code} <- LocusBackends.read_refusal(body),
         true <- LocusBackends.status(code) == status do
      {:refused, Opus.Programs.Box.refusal_name(code), Opus.Programs.Box.boot_header(headers)}
    else
      _ -> {:unreadable, {:status, status}}
    end
  end
end
