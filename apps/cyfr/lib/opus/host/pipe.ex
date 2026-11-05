# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.Pipe do
  @moduledoc """
  The host calls a runner makes for its catalyst's program pipe
  (`cyfr:process/pipe`): `pipe_open`, `pipe_send`, `pipe_recv` and
  `pipe_close` (`Prima.HostAPI`). The catalyst never holds a credential or
  a route of its own: CYFR resolves the login need it names through the
  run's authority and speaks to the program's box itself
  (`Opus.Programs`).

  `Opus.Host` verifies each call and reads its args before it reaches
  here. The attempt must be held by the calling runner and live, as for an
  `attached_fetch` (`:chain`); otherwise the call is `lost` or
  `unavailable` and nothing is resolved.

  ## Open

  What decides is the run's admitted authority and what CYFR holds for the
  attempt, never the request, in this order:

    1. the need is granted: the running node's manifest, held to its
       trusted digest (`Opus.Host.node_needs/2`), declares `need` as a
       `login` need, and no other login need of it names the same program,
       since the edge records no need name for its binding to be told by;
       anything else is `denied`;
    2. `Sanctum.Mount.resolve/4` mounts the run's binding of the need: the
       binding live, the entry active at the consented digest and a login
       entry, its destination naming a program row of the athanor that
       stands, enabled, with a kept home, and only then a `once` binding
       used; a binding that is no login entry's, or none, is `denied`, and
       one that no longer serves (`setup_required`) names why;
    3. the row is the program the need names (`denied` otherwise: the
       binding mounts another program);
    4. the key is 1 to #{256} bytes, and the session's key on the box is
       derived from it and the node's name-level reference, so two
       components bound to one program never share a session.

  Then `Opus.Programs.pipe_open/5` opens the session for the attempt: a
  session belongs to the row, the home and the key, so a later attempt
  opening the key attaches to it while its program runs.

  ## Send, read, close

  Each acts on a session its attempt opened, and `denied` on any other.
  A send to a session whose program ended is the guest error `ended`; a
  read of one answers its last lines and `running: false`, and a session
  CYFR no longer holds answers no lines and `running: false`. A read waits
  at most `Prima.HostAPI.max_pipe_wait_ms/0` and its answer to the box is
  awaited within the host call's window; it carries as many lines as fit
  `Prima.HostAPI.max_answer_bytes/0`, the rest left for the next read,
  which names the last one it got. A close ends the session and its
  program; one of a session CYFR no longer holds answers `:ok`.

  A refusal of the open's first three steps is recorded as a denial of
  the attempt's component (`Sanctum.Policy.Enforcement.record/1`), its
  reason led by `pipe:`. Nothing that passes through a pipe is logged.
  """

  require Logger

  alias Opus.{Attempt, Programs}
  alias Prima.HostAPI

  @login "login"
  @max_key_bytes 256
  # What an answer's envelope and sealing take beside its lines.
  @answer_margin 65_536
  # The host call's window less the margin a slow answer needs: what a
  # read awaits the box for beyond its wait.
  @recv_slack_ms Prima.WorkerAuth.window_ms() - HostAPI.max_pipe_wait_ms() - 5_000

  @doc "Open the session of `key` on the program the login need `need` is bound to."
  @spec open(Attempt.caller(), String.t(), String.t(), [String.t()]) ::
          {:ok, HostAPI.pipe_opened()} | {:error, term()}
  def open(caller, need, key, argv) do
    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain),
         {:ok, program} <- login_need(caller, chain, need),
         {:ok, home_id, row} <- mount(chain, need),
         :ok <- same_program(chain, need, program, row),
         {:ok, key} <- session_key(chain, need, key) do
      case Programs.pipe_open(row, home_id, key, argv, caller.attempt) do
        {:ok, opened} -> {:ok, opened}
        {:error, reason} -> programs_refusal(reason)
      end
    end
  end

  @doc "Write `lines` to the program of the attempt's `session`."
  @spec send(Attempt.caller(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def send(caller, session, lines) do
    with {:ok, _chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case Programs.pipe_send(caller.athanor_id, caller.attempt, session, lines) do
        :ok -> :ok
        {:error, reason} -> programs_refusal(reason)
      end
    end
  end

  @doc "The lines of the attempt's `session` past `after_seq`, as many as an answer carries."
  @spec recv(Attempt.caller(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, HostAPI.pipe_recv()} | {:error, term()}
  def recv(caller, session, after_seq, max_wait_ms) do
    wait = min(max_wait_ms, HostAPI.max_pipe_wait_ms())

    with {:ok, _chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case Programs.pipe_recv(
             caller.athanor_id,
             caller.attempt,
             session,
             after_seq,
             wait,
             @recv_slack_ms
           ) do
        {:ok, answer} -> fit(answer)
        {:error, reason} -> programs_refusal(reason)
      end
    end
  end

  @doc "End the attempt's `session` and its program."
  @spec close(Attempt.caller(), String.t()) :: :ok | {:error, term()}
  def close(caller, session) do
    with {:ok, _chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case Programs.pipe_close(caller.athanor_id, caller.attempt, session) do
        :ok -> :ok
        {:error, reason} -> programs_refusal(reason)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Open
  # ---------------------------------------------------------------------------

  # 1. The need is the node's own login need, the only one naming its
  # program.
  defp login_need(caller, chain, need) do
    with {:ok, needs} <- Opus.Host.node_needs(caller, chain),
         %{kind: @login, program: program} <- Enum.find(needs, &(&1.name == need)),
         [_one] <- Enum.filter(needs, &match?(%{kind: @login, program: ^program}, &1)) do
      {:ok, program}
    else
      _undeclared_or_ambiguous ->
        denied(chain, "the component declares no login need #{need} of its own")
    end
  end

  # 2. The vault mounts the run's binding of the need.
  defp mount(chain, need) do
    case Sanctum.Mount.resolve(chain.ctx, chain.authority, need, chain.root_execution_id) do
      {:ok, {:mount, home_id, row}} ->
        {:ok, home_id, row}

      {:error, reason} when reason in [:anonymous_denied, :connection_not_granted] ->
        denied(chain, "the run binds no login entry for #{need}")

      {:error, reason} when reason in [:unavailable, :database_error] ->
        {:error, :unavailable}

      {:error, {:unavailable, _store}} ->
        {:error, :unavailable}

      {:error, reason} ->
        setup_required(mount_sentence(need, reason))
    end
  end

  # 3. The binding mounts the program the need names.
  defp same_program(chain, need, program, row) do
    if row.name == program,
      do: :ok,
      else: denied(chain, "the binding of #{need} mounts another program than #{program}")
  end

  # 4. A key of the node's own: two components bound to one program never
  # reach each other's session.
  defp session_key(chain, need, key) do
    with true <- byte_size(key) <= @max_key_bytes,
         {:ok, node} <- Prima.ComponentRef.to_name_ref(chain.component_ref) do
      digest = [node, need, key] |> Enum.join(<<0>>) |> Prima.Digest.sha256_hex()
      {:ok, "pipe-" <> binary_part(digest, 0, 40)}
    else
      {:error, _unparsed} ->
        {:error, :lost}

      false ->
        guest_error("invalid_request", "A pipe key is at most #{@max_key_bytes} bytes.")
    end
  end

  defp mount_sentence(need, {:not_built, :shared_login}),
    do: "The login entry bound to #{need} is shared with you, and a shared one cannot run yet."

  defp mount_sentence(need, {:program_unavailable, program}),
    do:
      "The program #{program} that #{need} runs is not an enabled program with a kept " <>
        "folder here."

  defp mount_sentence(need, :grant_expired), do: "The grant of #{need} has expired."

  defp mount_sentence(need, {:entry_unavailable, _name, status}),
    do: "The login entry bound to #{need} is #{status}."

  defp mount_sentence(need, _reason),
    do: "The login entry bound to #{need} no longer serves it; grant it again."

  # ---------------------------------------------------------------------------
  # Answers
  # ---------------------------------------------------------------------------

  # As many lines as the answer's bound carries, in order; the rest stay
  # in the session's buffer for the next read. A first line no answer can
  # carry is refused rather than held forever.
  defp fit(%{lines: lines} = answer) do
    budget = HostAPI.max_answer_bytes() - @answer_margin

    {kept, _left} =
      Enum.reduce_while(lines, {[], budget}, fn line, {kept, left} ->
        size = byte_size(Jason.encode!(%{"seq" => line.seq, "text" => line.text})) + 1

        if size <= left,
          do: {:cont, {[line | kept], left - size}},
          else: {:halt, {kept, left}}
      end)

    case {lines, kept} do
      {[_ | _], []} ->
        guest_error("too_large", "The program wrote a line no answer can carry.")

      _ ->
        {:ok,
         %{
           lines: Enum.reverse(kept),
           dropped: answer.dropped,
           running: answer.running or length(kept) < length(lines)
         }}
    end
  end

  # How the programs controller's refusals reach the guest.
  defp programs_refusal(:denied), do: {:error, :denied}
  defp programs_refusal(:ended), do: guest_error("ended", "The program has ended.")

  defp programs_refusal({:refused, :home_over_cap, _boot}),
    do: setup_required("The program's folder is past its cap; reset it on the Programs page.")

  defp programs_refusal({:refused, :capacity, _boot}),
    do: guest_error("busy", "The box runs as many programs as it may; try again later.")

  defp programs_refusal({:refused, code, _boot}) when code in [:bad_request, :too_large],
    do: guest_error("invalid_request", "The program refused what the pipe sent.")

  defp programs_refusal({:invalid, _error}),
    do: guest_error("invalid_request", "A key, argument or line the pipe refuses.")

  defp programs_refusal(:backends_not_configured),
    do: setup_required("No backends service runs programs on this installation.")

  defp programs_refusal(:disclosure_refused),
    do: setup_required("The program's settings name a credential it may not read.")

  defp programs_refusal(reason) do
    Logger.warning("[Opus.Host.Pipe] the programs controller refused: #{inspect(reason)}")
    {:error, :unavailable}
  end

  defp denied(chain, sentence) do
    Sanctum.Policy.Enforcement.record(%{
      ctx: chain.ctx,
      component_ref: chain.component_ref,
      component_type: :catalyst,
      event_type: :denied,
      decision: :denied,
      decision_reason: "pipe: " <> sentence
    })

    {:error, :denied}
  end

  defp setup_required(sentence), do: guest_error("setup_required", sentence)

  defp guest_error(type, message), do: {:error, {:guest_error, type, message}}
end
