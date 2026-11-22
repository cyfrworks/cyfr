# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Session do
  @moduledoc """
  The session routes of `Prima.LocusBackends`: `open/2` and the close
  route (`close/3`), which the box alone speaks, each for one lifetime
  under the grant of the version in its name
  (`Opus.Programs.Box`, "Sessions"); and what a holder speaks under the
  grant `Opus.Programs.hold/1` answered, `send/3` and `recv/4` of a `run`
  session, or `input/3`, `output/4` and `resize/4` of a `terminal` one.

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
  @open_timeout_ms 310_000

  @type grant :: Opus.Programs.Box.grant()
  @type refusal ::
          {:refused, atom(), String.t() | nil}
          | :backends_unavailable
          | {:unreadable, term()}
          | {:invalid, term()}

  @doc """
  Open the session of `params.lifetime`: the service answers the process running for
  it, or starts its program with `argv`, mode `:run` on pipes and mode
  `:terminal` on a pseudo-terminal of `rows` by `cols`, in the kept home
  it names. `:timeout_ms` (default #{@open_timeout_ms}) bounds the wait
  for the answer.
  """
  @spec open(grant(), %{
          required(:lifetime) => Opus.Programs.Box.lifetime(),
          optional(:argv) => Opus.Programs.Words.t(),
          optional(:rows) => pos_integer(),
          optional(:cols) => pos_integer(),
          optional(:timeout_ms) => pos_integer(),
          optional(atom()) => term()
        }) ::
          {:ok, %{session: String.t(), resumed: boolean()}}
          | {:error, refusal()}
  def open(grant, %{lifetime: lifetime} = params) do
    message =
      base(:open, grant)
      |> Map.merge(of_lifetime(lifetime))
      |> Map.merge(%{
        argv: params |> Map.get(:argv, Opus.Programs.Words.new([])) |> Opus.Programs.Words.list(),
        rows: Map.get(params, :rows),
        cols: Map.get(params, :cols)
      })

    with {:ok, answer} <- post(grant, message, Map.get(params, :timeout_ms, @open_timeout_ms)) do
      {:ok, Map.take(answer, [:session, :resumed])}
    end
  end

  @doc """
  Write `lines` to the session's process; `:ended` once it no longer runs.
  The answer is awaited `timeout_ms` (default #{@send_timeout_ms}).
  """
  @spec send(grant(), String.t(), [String.t()], pos_integer()) ::
          {:ok, :running | :ended} | {:error, refusal()}
  def send(grant, session, lines, timeout_ms \\ @send_timeout_ms) when is_list(lines) do
    message = Map.merge(base(:send, grant), %{session: session, lines: lines})

    with {:ok, %{status: status}} <- post(grant, message, timeout_ms),
         do: {:ok, status}
  end

  @doc """
  The lines past `after`, waiting up to `max_wait_ms` for one or the
  process's end; idempotent, so a lost answer is asked for again by the
  same `after`. An ended session's `exit_code` is its process's status when
  it exited of its own accord, nil otherwise. The answer is awaited for
  the wait and `slack_ms` beyond it (default #{@slack_ms}).
  """
  @spec recv(grant(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok,
           %{
             lines: [LocusBackends.line()],
             dropped: non_neg_integer(),
             running: boolean(),
             exit_code: 0..255 | nil
           }}
          | {:error, refusal()}
  def recv(grant, session, after_seq, max_wait_ms, slack_ms \\ @slack_ms) do
    max_wait_ms = min(max_wait_ms, LocusBackends.max_recv_wait_ms())

    message =
      Map.merge(base(:recv, grant), %{
        session: session,
        after: after_seq,
        max_wait_ms: max_wait_ms
      })

    post(grant, message, max_wait_ms + slack_ms)
  end

  @doc """
  Write `bytes` to a terminal session as they are; `:ended` once it no
  longer runs. The answer is awaited `timeout_ms` (default #{@send_timeout_ms}).
  """
  @spec input(grant(), String.t(), binary(), pos_integer()) ::
          {:ok, :running | :ended} | {:error, refusal()}
  def input(grant, session, bytes, timeout_ms \\ @send_timeout_ms) when is_binary(bytes) do
    message = Map.merge(base(:input, grant), %{session: session, bytes: bytes})

    with {:ok, %{status: status}} <- post(grant, message, timeout_ms),
         do: {:ok, status}
  end

  @doc "Set a terminal session's size; `:ended` once it no longer runs."
  @spec resize(grant(), String.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, :running | :ended} | {:error, refusal()}
  def resize(grant, session, rows, cols, timeout_ms \\ @send_timeout_ms) do
    message = Map.merge(base(:resize, grant), %{session: session, rows: rows, cols: cols})

    with {:ok, %{status: status}} <- post(grant, message, timeout_ms),
         do: {:ok, status}
  end

  @doc """
  A terminal session's chunks of bytes past `after`, masked, as `recv/5`
  answers a run's lines.
  """
  @spec output(grant(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok,
           %{
             chunks: [LocusBackends.chunk()],
             dropped: non_neg_integer(),
             running: boolean(),
             exit_code: 0..255 | nil
           }}
          | {:error, refusal()}
  def output(grant, session, after_seq, max_wait_ms, slack_ms \\ @slack_ms) do
    max_wait_ms = min(max_wait_ms, LocusBackends.max_recv_wait_ms())

    message =
      Map.merge(base(:output, grant), %{
        session: session,
        after: after_seq,
        max_wait_ms: max_wait_ms
      })

    post(grant, message, max_wait_ms + slack_ms)
  end

  @doc """
  End `lifetime` on the close route, proved by `grant`, of the version in
  its name, at the service's current boot: `:ok` once the service says
  its place is back. The answer is awaited `timeout_ms`.
  """
  @spec close(grant(), Opus.Programs.Box.lifetime(), pos_integer()) :: :ok | {:error, refusal()}
  def close(grant, lifetime, timeout_ms) do
    message = Map.merge(named(grant), of_lifetime(lifetime))
    max = LocusBackends.max_control_bytes()

    with {:ok, body} <- encoded(LocusBackends.encode_close(message)),
         {:ok, _closed} <-
           request(grant, :close, body, timeout_ms, max, &LocusBackends.read_close_answer/1),
         do: :ok
  end

  defp base(type, grant), do: Map.put(named(grant), :type, type)

  defp of_lifetime(lifetime) do
    lifetime
    |> Map.take([:program, :home_id, :key, :mode])
    |> Map.put(:lifetime, lifetime.id)
  end

  defp named(grant),
    do: %{owner: %{athanor: grant.athanor, server: grant.server}, e: grant.epoch}

  defp post(grant, message, timeout_ms) do
    max = LocusBackends.max_session_bytes()
    read = &LocusBackends.read_session_answer(message.type, &1)

    with {:ok, body} <- encoded(LocusBackends.encode_session(message)),
         do: request(grant, :session, body, timeout_ms, max, read)
  end

  defp request(grant, operation, body, timeout_ms, max, read) do
    invoke = %{
      athanor: grant.athanor,
      server: grant.server,
      generation: grant.generation,
      epoch: grant.epoch,
      boot: grant.boot,
      ts: System.os_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    with {:ok, header} <- sign(grant, invoke, body) do
      headers = [{"content-type", "application/json"}, {LocusBackends.auth_header(), header}]

      opts = [
        receive_timeout: timeout_ms,
        private_policy: :operator,
        max_response_bytes: max
      ]

      url = grant.url <> LocusBackends.route(operation)

      case Sanctum.Egress.pinned_request(:post, url, headers, body, opts) do
        {:ok, 200, _headers, resp_body} ->
          case read.(resp_body) do
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

  defp encoded({:ok, body}), do: {:ok, body}
  defp encoded({:error, error}), do: {:error, {:invalid, error}}

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
