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

  An open of a program that loads the person's packs (`loads_packs: true`,
  which the box gives from its owner's sync) first makes the service hold
  their copy for the lifetime, spending nothing of it: it reads the set's
  digest (`Compendium.pack_digest/2`) and sends `packs_hold`; a `missing`
  copy is read by that digest (`Compendium.pack_view/3`) and put in
  `packs_put`s, each part awaited before the next. A selection that moved
  on since the digest was read is begun again from the new one, three
  times at most; a fourth move ends the start `:packs_moved`, and a hold
  or a put that fails `:packs_unready`, before the open is sent. A put
  whose first part meets another put of the person's under way
  (`packs_busy`) holds again every 500 ms, finding the generation held
  once that put is done or missing, to put, once it failed or was
  abandoned, for at most 60 s or to the open's own deadline
  (`within_ms`), whichever comes first, then ends `:packs_unready`; the
  archive it built is put again, the set not read again. The packs are
  read under the grant's athanor, the one the requests are signed for. The open
  then names as its `packs` the digest the `held` answer named: the one
  read, but for an open of a lifetime whose session lives, which the
  service holds at the generation that session's open named, packs changed
  since or not, and the open is resumed; the packs as they stand reach the
  next lifetime.

  Answers are the wire's (`Prima.LocusBackends.read_session_answer/2`):
  a `recv` or an `output` of an ended session carries its `ended_by`,
  what ended its process for memory (`:cap`, `:machine` or `:either`) or
  nil, and a `send`, `input` or `resize` to one answers `:ended`, or
  `{:ended_by, cause}` where memory ended it. A refusal is
  `{:error, {:refused, code, boot}}` with the code a box answers it as
  (`Opus.Programs.Box.refusal_name/1`) and the service boot id the answer
  named, a `capacity` that carries what holds the pool as
  `{:capacity, held}` (`Prima.LocusPool.t:held/0`); a service that cannot be reached
  `{:error, :backends_unavailable}`; an answer that does not read
  `{:error, {:unreadable, error}}`.
  """

  alias Prima.LocusBackends

  # The wait beyond a recv's own, for the round trip.
  @slack_ms 10_000
  @send_timeout_ms 30_000
  @open_timeout_ms 310_000

  @type grant :: Opus.Programs.Box.grant()

  @typedoc "What a write answers: the session runs, or ended, and why where memory ended it."
  @type written :: :running | :ended | {:ended_by, LocusBackends.ended_by()}
  @type refusal ::
          {:refused, atom() | {:capacity, Prima.LocusPool.held()}, String.t() | nil}
          | :backends_unavailable
          | {:unreadable, term()}
          | {:invalid, term()}

  # How many times a start begins again from a selection that moved on.
  @pack_moves 3

  # A start whose put meets another put of the person's under way
  # (`packs_busy`) holds again every @busy_every_ms, for at most
  # @busy_wait_ms from its first such refusal: the largest set the store
  # hands (128 MiB in 8,192 files) is put through the service in under
  # 5 s on one quarter of the verification host. A put whose start was
  # abandoned mid-way is dropped by the keeper its idle bound after its
  # last part (`packview.IdleFor`, 10 s), so that bound and one more hold
  # are well inside the wait; the shared vectors' `pack_waits` pin the
  # three on both sides.
  @busy_every_ms 500
  @busy_wait_ms 60_000

  @doc false
  # The wait's bounds, which the shared vectors' `pack_waits` pin.
  @spec busy_bounds() :: %{every_ms: pos_integer(), wait_ms: pos_integer()}
  def busy_bounds, do: %{every_ms: @busy_every_ms, wait_ms: @busy_wait_ms}

  @doc """
  Open the session of `params.lifetime`: the service answers the process running for
  it, or starts its program with `argv`, mode `:run` on pipes and mode
  `:terminal` on a pseudo-terminal of `rows` by `cols`, in the kept home
  it names, with the person's packs held first when `loads_packs` (see
  the moduledoc). `:timeout_ms` (default #{@open_timeout_ms}) bounds the
  wait for each answer, and `:within_ms` (default the same) the wait for
  another put of the person's.
  """
  @spec open(grant(), %{
          required(:lifetime) => Opus.Programs.Box.lifetime(),
          optional(:argv) => Opus.Programs.Words.t(),
          optional(:rows) => pos_integer(),
          optional(:cols) => pos_integer(),
          optional(:loads_packs) => boolean(),
          optional(:timeout_ms) => pos_integer(),
          optional(:within_ms) => non_neg_integer(),
          optional(atom()) => term()
        }) ::
          {:ok, %{session: String.t(), resumed: boolean()}}
          | {:error, refusal() | :packs_unready | :packs_moved}
  def open(grant, %{lifetime: lifetime} = params) do
    timeout_ms = Map.get(params, :timeout_ms, @open_timeout_ms)
    argv = params |> Map.get(:argv, Opus.Programs.Words.new([])) |> Opus.Programs.Words.list()

    until = now_ms() + Map.get(params, :within_ms, timeout_ms)
    loads_packs = Map.get(params, :loads_packs, false)

    with {:ok, packs} <- packs(grant, lifetime, loads_packs, timeout_ms, until),
         message =
           base(:open, grant)
           |> Map.merge(of_lifetime(lifetime))
           |> Map.merge(%{
             argv: argv,
             rows: Map.get(params, :rows),
             cols: Map.get(params, :cols),
             packs: packs
           }),
         {:ok, answer} <- post(grant, message, timeout_ms) do
      {:ok, Map.take(answer, [:session, :resumed])}
    end
  end

  # The digest the open names, the one the service holds for the
  # lifetime; nil for a program that loads no packs. Read under the grant's
  # athanor, which the requests are signed for. `until` is the open's own
  # deadline (monotonic milliseconds), which ends a wait for another put.
  defp packs(_grant, _lifetime, false, _timeout_ms, _until), do: {:ok, nil}

  defp packs(grant, lifetime, true, timeout_ms, until) do
    ctx = Sanctum.Context.internal(athanor_id: grant.athanor, scope: :athanor)

    start = %{
      grant: grant,
      lifetime: lifetime,
      ctx: ctx,
      timeout_ms: timeout_ms,
      until: until,
      busy_until: nil,
      built: nil
    }

    case Compendium.pack_digest(ctx, grant.athanor) do
      {:ok, digest} -> held(start, digest, 0)
      {:error, _unread} -> {:error, :packs_unready}
    end
  end

  # `busy_until` is when a start that met a put under way stops holding
  # again (monotonic milliseconds), nil until it has met one; `built` the
  # archive of a digest it put, kept for its put again.
  defp held(start, digest, moves) do
    hold =
      base(:packs_hold, start.grant)
      |> Map.merge(of_lifetime(start.lifetime))
      |> Map.put(:digest, digest)

    case post(start.grant, hold, start.timeout_ms) do
      {:ok, %{state: :held, digest: held}} ->
        {:ok, held}

      {:ok, %{state: :missing}} ->
        case built(start, digest) do
          {:ok, archive} ->
            start = %{start | built: {digest, archive}}

            case put(start.grant, %{hold | type: :packs_put}, archive, 0, start.timeout_ms) do
              :busy -> busy(start, digest, moves)
              put -> put
            end

          {:moved, now} when moves < @pack_moves ->
            held(start, now, moves + 1)

          {:moved, _now} ->
            {:error, :packs_moved}

          {:error, _unread} ->
            {:error, :packs_unready}
        end

      failed ->
        unready(failed)
    end
  end

  # The archive of `digest`: the one this start built, or read by it.
  defp built(%{built: {digest, archive}}, digest), do: {:ok, archive}

  defp built(start, digest) do
    case Compendium.pack_view(start.ctx, start.grant.athanor, digest) do
      {:ok, %{archive: archive}} -> {:ok, archive}
      moved_or_unread -> moved_or_unread
    end
  end

  # Another put of the person's is under way: the start holds again, which
  # finds the generation held once that put is done, or missing, to put,
  # once it failed or was abandoned; past the wait's bound, or the open's
  # deadline where that comes first, it is the packs not made ready.
  defp busy(%{busy_until: nil} = start, digest, moves),
    do: busy(%{start | busy_until: min(now_ms() + @busy_wait_ms, start.until)}, digest, moves)

  defp busy(start, digest, moves) do
    if now_ms() + @busy_every_ms > start.busy_until do
      {:error, :packs_unready}
    else
      # sleep-ok: a start whose put met another put of the person's waits a moment before it holds again
      Process.sleep(@busy_every_ms)
      held(start, digest, moves)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The archive in parts of at most the wire's bound, each answered before
  # the next is sent: `taken`, and the last `held`.
  defp put(grant, message, archive, seq, timeout_ms) do
    size = min(byte_size(archive), LocusBackends.bounds().max_pack_part_bytes)
    <<part::binary-size(^size), rest::binary>> = archive
    last = rest == ""

    case {post(grant, Map.merge(message, %{seq: seq, last: last, part: part}), timeout_ms), last} do
      {{:ok, %{state: :taken}}, false} -> put(grant, message, rest, seq + 1, timeout_ms)
      {{:ok, %{state: :held, digest: held}}, true} -> {:ok, held}
      {{:error, {:refused, :packs_busy, _boot}}, _last} when seq == 0 -> :busy
      {failed, _last} -> unready(failed)
    end
  end

  # A boot the service no longer runs keeps its meaning for the box; every
  # other failure of a hold or a put is the packs not made ready.
  defp unready({:error, {:refused, :stale_boot, _boot}} = stale), do: stale
  defp unready(_failed), do: {:error, :packs_unready}

  @doc """
  Write `lines` to the session's process; `:ended` once it no longer runs.
  The answer is awaited `timeout_ms` (default #{@send_timeout_ms}).
  """
  @spec send(grant(), String.t(), [String.t()], pos_integer()) ::
          {:ok, written()} | {:error, refusal()}
  def send(grant, session, lines, timeout_ms \\ @send_timeout_ms) when is_list(lines) do
    message = Map.merge(base(:send, grant), %{session: session, lines: lines})

    with {:ok, answer} <- post(grant, message, timeout_ms),
         do: {:ok, written(answer)}
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
             exit_code: 0..255 | nil,
             ended_by: LocusBackends.ended_by() | nil
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
          {:ok, written()} | {:error, refusal()}
  def input(grant, session, bytes, timeout_ms \\ @send_timeout_ms) when is_binary(bytes) do
    message = Map.merge(base(:input, grant), %{session: session, bytes: bytes})

    with {:ok, answer} <- post(grant, message, timeout_ms),
         do: {:ok, written(answer)}
  end

  @doc "Set a terminal session's size; `:ended` once it no longer runs."
  @spec resize(grant(), String.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, written()} | {:error, refusal()}
  def resize(grant, session, rows, cols, timeout_ms \\ @send_timeout_ms) do
    message = Map.merge(base(:resize, grant), %{session: session, rows: rows, cols: cols})

    with {:ok, answer} <- post(grant, message, timeout_ms),
         do: {:ok, written(answer)}
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
             exit_code: 0..255 | nil,
             ended_by: LocusBackends.ended_by() | nil
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

  defp written(%{status: :running}), do: :running
  defp written(%{status: :ended, ended_by: nil}), do: :ended
  defp written(%{status: :ended, ended_by: cause}), do: {:ended_by, cause}

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
    with {:ok, refusal} <- LocusBackends.read_refusal(body),
         code = LocusBackends.code(refusal),
         true <- LocusBackends.status(code) == status do
      {:refused, named_refusal(refusal), Opus.Programs.Box.boot_header(headers)}
    else
      _ -> {:unreadable, {:status, status}}
    end
  end

  # A capacity for room keeps what holds the pool, which the refusal's
  # sentence names (`Opus.Programs.full/4`); every other refusal is its code.
  defp named_refusal({:capacity, _held} = capacity), do: capacity
  defp named_refusal(code), do: Opus.Programs.Box.refusal_name(code)
end
