# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.Client do
  @moduledoc """
  CYFR's client of the Locus builds service, over `Cyfr.BuilderProtocol`.
  `Compendium.Builds` reaches the service through it and nothing else
  does.

  The service is the one `Cyfr.RuntimeConfig.locus_builds_url/0` and
  `locus_builds_key/0` name (`CYFR_LOCUS_BUILDS_URL`,
  `CYFR_LOCUS_BUILDS_KEY`); with either missing every function answers
  `{:error, :not_configured}` and no request is made. A request is a
  `POST` to its route whose body the protocol encodes and whose
  `x-cyfr-auth` header is `Cyfr.BuilderProtocol.request_header/3` over
  that body, signed with the key derived from the service key, under a
  fresh nonce. The key reaches no log, outcome or message.

  ## A build's answer

  The answer is read as it arrives, a line at a time, whatever its HTTP
  status: each progress line is handed to `:on_progress` in the order the
  builder wrote it, and the first result or refusal ends the answer — the
  client stops reading there. The whole answer is held to
  `Cyfr.BuilderProtocol.max_response_bytes/0` while it streams
  (`Cyfr.BoundedBody`), and every line is read strictly
  (`Cyfr.BuilderProtocol.read_line/1`): the builder is another trust
  domain, so a line that does not read, a path that is not a safe relative
  one, outputs past their bounds and a digest that is not its bytes' each
  end the request as `:malformed`. A result is then verified here before
  it is answered: it must be of the language and type asked for, a
  component's bytes must validate (`Compendium.WasmValidator`) and its
  digest, size and exports are derived from that validation, never taken
  from the builder; a tincture's digest is `Cyfr.Digest.file_set/1` of the
  files read.

  ## How a build ends

  `build/2` answers `{:ok, built}` for a verified result and otherwise one
  of, each distinct:

    * `:not_configured` — this server has no builds service.
    * `{:sources, error}` — the request cannot be written: the sources
      pass a bound of the protocol or name an unsafe path
      (`t:Cyfr.BuilderProtocol.read_error/0`). Nothing was sent.
    * `:unreachable` — no connection was made. Nothing was asked.
    * `:disconnected` — the connection, or the answer, ended before a
      result or a refusal arrived. The build may have run.
    * `:deadline` — the deadline passed with the answer still open, and
      the request was ended here.
    * `{:refused, refusal, diagnostics}` — the builder's own refusal by
      class (`t:Cyfr.BuilderProtocol.refusal/0`): `capacity`, `timeout`,
      `memory` with its bound, `unavailable`, `failed` with a status or a
      signal, `unauthorized`, `malformed`; with the build's log lines.
    * `{:protocol_mismatch, builder, client}` — the builder speaks another
      version of the protocol, by its refusal or by the version its lines
      carry.
    * `{:malformed, reason}` — the answer is not the protocol's, or its
      result did not verify.

  ## Cancellation

  The request runs in a process of its own under
  `Compendium.Builds.TaskSupervisor`, linked to the caller. The caller
  waits for it until the deadline and a grace for the builder's own
  `timeout` answer, then ends it; a caller that is killed — a cancelled or
  timed-out tool call, a transport whose client hung up — takes the
  request process with it. Either way the connection closes, which is how
  the builder learns to retire the build, and nothing of an unfinished
  answer is returned.
  """

  require Logger

  alias Cyfr.{BoundedBody, BuilderProtocol, RuntimeConfig}

  @supervisor Compendium.Builds.TaskSupervisor
  @connect_timeout_ms 5_000
  @health_timeout_ms 5_000
  # How long past the deadline the builder's own `timeout` refusal, which
  # carries the build's log, is waited for before the request is ended:
  # this, or the time the build was given when that is less.
  @grace_ms 10_000
  @state :builds_answer

  @typedoc "What a progress line is handed to: its stage and message."
  @type on_progress :: (BuilderProtocol.stage(), String.t() -> any())

  @typedoc "A build to ask for: whose it is, what of, from which sources."
  @type request :: %{
          athanor_id: String.t(),
          target_type: BuilderProtocol.target_type(),
          resolve: boolean(),
          sources: %{String.t() => binary()}
        }

  @typedoc """
  A verified build. A component's carries its bytes, the lock the build
  left (or nil) and what validating the bytes derived; a tincture's its
  files and their file-set digest.
  """
  @type built :: %{
          required(:digest) => String.t(),
          required(:size) => non_neg_integer(),
          required(:exports) => [String.t()],
          required(:language) => String.t(),
          required(:target_type) => String.t(),
          required(:diagnostics) => [String.t()],
          optional(:wasm_bytes) => binary(),
          optional(:lockfile) => binary() | nil,
          optional(:output_files) => %{String.t() => binary()}
        }

  @type outcome ::
          :not_configured
          | {:sources, BuilderProtocol.read_error()}
          | :unreachable
          | :disconnected
          | :deadline
          | {:refused, BuilderProtocol.refusal(), [String.t()]}
          | {:protocol_mismatch, pos_integer(), pos_integer() | nil}
          | {:malformed, term()}

  @doc """
  Build `request` on the builds service and answer the verified build, or
  how it ended (`t:outcome/0`).

  Options: `:deadline` (required), the instant in Unix milliseconds by
  which the build must have finished, sent to the builder and held here;
  `:on_progress`, called in the request's process with each progress
  line's stage and message, in order; `:grace_ms`, how long past the
  deadline the builder's own answer is waited for (ten seconds, or the
  time to the deadline when that is less).
  """
  @spec build(request(), keyword()) :: {:ok, built()} | {:error, outcome()}
  def build(%{athanor_id: _, target_type: target_type, resolve: _, sources: _} = request, opts)
      when is_atom(target_type) do
    deadline = Keyword.fetch!(opts, :deadline)
    on_progress = Keyword.get(opts, :on_progress, fn _stage, _message -> :ok end)
    budget_ms = max(deadline - System.system_time(:millisecond), 0)
    grace_ms = Keyword.get(opts, :grace_ms, min(@grace_ms, budget_ms))

    wire =
      request
      |> Map.take([:athanor_id, :target_type, :resolve, :sources])
      |> Map.merge(%{language: BuilderProtocol.language_for(target_type), deadline: deadline})

    with {:ok, service} <- service(),
         {:ok, body} <- encode(wire),
         {:ok, header} <- sign(service, body),
         {:ok, result} <- stream(service.url, header, body, on_progress, deadline, grace_ms) do
      verify(result, wire)
    end
  end

  @doc """
  The toolchains the builds service reports on its health route, by
  language (`t:Cyfr.BuilderProtocol.health/0`).
  """
  @spec toolchains() ::
          {:ok, %{BuilderProtocol.language() => BuilderProtocol.toolchain()}}
          | {:error, outcome()}
  def toolchains do
    body = BuilderProtocol.encode_health_request()
    # One line without outputs: a health line, or a refusal and its log.
    max = BuilderProtocol.max_log_bytes()

    with {:ok, service} <- service(),
         {:ok, header} <- sign(service, body) do
      response =
        service.url
        |> request_options(:health, header, body)
        |> Keyword.merge(receive_timeout: @health_timeout_ms, into: BoundedBody.collector(max))
        |> Req.request()

      with {:ok, %Req.Response{status: status} = resp} <- response,
           {:ok, raw} <- BoundedBody.read(resp, max) do
        health(read_line(String.trim_trailing(raw, "\n"), status))
      else
        {:error, {:response_too_large, _size, _max} = too_large} ->
          {:error, {:malformed, too_large}}

        {:error, exception} ->
          {:error, transport(exception, :no_deadline)}
      end
    end
  end

  defp health({:ok, {:health, %{toolchains: toolchains}}}), do: {:ok, toolchains}

  defp health({:ok, {:refusal, refusal, diagnostics}}),
    do: {:error, refused(refusal, diagnostics)}

  defp health({:ok, _other_line}), do: {:error, {:malformed, :unexpected_line}}
  defp health({:error, outcome}), do: {:error, outcome}

  # ---------------------------------------------------------------------------
  # The request
  # ---------------------------------------------------------------------------

  defp service do
    case {RuntimeConfig.locus_builds_url(), RuntimeConfig.locus_builds_key()} do
      {url, <<_::256>> = key} when is_binary(url) ->
        {:ok, %{url: url, request_key: BuilderProtocol.request_key(key)}}

      _unconfigured ->
        {:error, :not_configured}
    end
  end

  defp encode(wire) do
    case BuilderProtocol.encode_request(wire) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, {:sources, error}}
    end
  end

  defp sign(service, body) do
    auth = %{ts: System.system_time(:millisecond), nonce: nonce()}

    case BuilderProtocol.request_header(service.request_key, auth, body) do
      {:ok, header} -> {:ok, header}
      {:error, invalid} -> {:error, {:malformed, {:request_header, invalid}}}
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp request_options(url, operation, header, body) do
    [
      method: :post,
      url: url <> BuilderProtocol.route(operation),
      headers: [{BuilderProtocol.auth_header(), header}, {"content-type", "application/json"}],
      body: body,
      connect_options: [timeout: @connect_timeout_ms],
      retry: false,
      redirect: false,
      compressed: false,
      decode_body: false
    ]
  end

  # The request's process is linked to this one, so whatever kills the
  # caller ends the request and closes its connection; ended at the
  # deadline here, it answers nothing. It is handed the signed header and
  # never the key.
  defp stream(url, header, body, on_progress, deadline, grace_ms) do
    wait_ms = max(deadline - System.system_time(:millisecond), 0) + grace_ms
    logger_metadata = Cyfr.LoggerContext.capture()

    task =
      Task.Supervisor.async(@supervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)

        url
        |> request_options(:build, header, body)
        |> Keyword.merge(
          receive_timeout: wait_ms + @connect_timeout_ms,
          into: reader(on_progress)
        )
        |> Req.request()
        |> answer(deadline)
      end)

    case Task.yield(task, wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} ->
        answer

      nil ->
        {:error, :deadline}

      # Seen only by a caller that traps exits: the request's process ended
      # without an answer.
      {:exit, reason} ->
        Logger.error("[Compendium.Builds.Client] the build request exited: #{exit_kind(reason)}")
        {:error, :disconnected}
    end
  end

  # An exit carries what it ended, and the request's process holds the
  # tenant's sources and the signed header: only the exit's kind is logged.
  defp exit_kind({%{__exception__: true, __struct__: exception}, _stacktrace}),
    do: inspect(exception)

  defp exit_kind({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp exit_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp exit_kind(_reason), do: "an exit of another shape"

  # ---------------------------------------------------------------------------
  # The answer, a line at a time
  # ---------------------------------------------------------------------------

  # The line being received is collected by `Cyfr.BoundedBody` against
  # what is left of the answer's bound, so the bound holds over the whole
  # answer without a second copy of it.
  defp reader(on_progress) do
    fn {:data, data}, {req, resp} ->
      state = resp.private[@state] || %{line: new_line(), left: max_response_bytes(), ended: nil}

      case read(data, state, resp.status, on_progress) do
        {:cont, state} -> {:cont, {req, put_state(resp, state)}}
        {:halt, state} -> {:halt, {req, put_state(resp, state)}}
      end
    end
  end

  defp read(data, state, status, on_progress) do
    case :binary.split(data, "\n") do
      [part] ->
        collect(part, state)

      [part, rest] ->
        with {:cont, state} <- collect(part, state),
             {:cont, state} <- finish_line(state, status, on_progress) do
          read(rest, state, status, on_progress)
        end
    end
  end

  defp collect("", state), do: {:cont, state}

  defp collect(part, %{left: left} = state) when left < 1,
    do: {:halt, %{state | ended: {:error, too_large(byte_size(part) - left)}}}

  defp collect(part, %{line: line, left: left} = state) do
    case BoundedBody.collector(left).({:data, part}, {nil, line}) do
      {:cont, {nil, line}} ->
        {:cont, %{state | line: line}}

      {:halt, {nil, line}} ->
        {:error, {:response_too_large, size, ^left}} = BoundedBody.read(line, left)
        {:halt, %{state | ended: {:error, too_large(size - left)}}}
    end
  end

  defp finish_line(%{line: line, left: left} = state, status, on_progress) do
    {:ok, text} = BoundedBody.read(line, left)
    state = %{state | line: new_line(), left: left - byte_size(text) - 1}

    case read_line(text, status) do
      {:ok, {:progress, stage, message}} ->
        on_progress.(stage, message)
        {:cont, state}

      {:ok, {:result, result}} ->
        {:halt, %{state | ended: {:ok, result}}}

      {:ok, {:refusal, refusal, diagnostics}} ->
        {:halt, %{state | ended: {:error, refused(refusal, diagnostics)}}}

      {:ok, {:health, _health}} ->
        {:halt, %{state | ended: {:error, {:malformed, :unexpected_line}}}}

      {:error, outcome} ->
        {:halt, %{state | ended: {:error, outcome}}}
    end
  end

  # A line at another version of the protocol is a builder of another
  # release. Anything else that does not read under a status other than
  # 200 is some other server's answer, named by its status.
  defp read_line(text, status) do
    case BuilderProtocol.read_line(text) do
      {:ok, line} ->
        {:ok, line}

      {:error, {:version, presented}} when is_integer(presented) and presented > 0 ->
        {:error, {:protocol_mismatch, presented, BuilderProtocol.version()}}

      {:error, _error} when status != 200 ->
        {:error, {:malformed, {:status, status}}}

      {:error, error} ->
        {:error, {:malformed, error}}
    end
  end

  # What the request came to. A transfer the reader ended carries its
  # reason; one that ran to its end without a result or a refusal has its
  # last line read, since the one line of a refusal need not end in a
  # newline, and is otherwise an answer that ended early.
  defp answer({:ok, %Req.Response{status: status} = resp}, _deadline) do
    case resp.private[@state] do
      %{ended: {_, _} = ended} ->
        ended

      %{line: line, left: left} ->
        {:ok, text} = BoundedBody.read(line, left)
        last_line(text, status)

      nil ->
        last_line("", status)
    end
  end

  defp answer({:error, exception}, deadline), do: {:error, transport(exception, deadline)}

  defp last_line("", 200), do: {:error, :disconnected}
  defp last_line("", status), do: {:error, {:malformed, {:status, status}}}

  defp last_line(text, status) do
    case read_line(text, status) do
      {:ok, {:result, result}} -> {:ok, result}
      {:ok, {:refusal, refusal, diagnostics}} -> {:error, refused(refusal, diagnostics)}
      {:ok, {:progress, _stage, _message}} -> {:error, :disconnected}
      {:ok, {:health, _health}} -> {:error, {:malformed, :unexpected_line}}
      {:error, outcome} -> {:error, outcome}
    end
  end

  defp refused({:protocol_mismatch, builder, client}, _diagnostics),
    do: {:protocol_mismatch, builder, client}

  defp refused(refusal, diagnostics), do: {:refused, refusal, diagnostics}

  # A connection that closed or was reset had been made; a timeout before
  # the deadline is the connection attempt's own, so none was; anything
  # else never connected.
  @lost [:closed, :econnreset, :econnaborted, :epipe, :enotconn]

  defp transport(%Req.TransportError{reason: reason}, _deadline) when reason in @lost,
    do: :disconnected

  defp transport(%Req.TransportError{reason: :timeout}, deadline) when is_integer(deadline) do
    if System.system_time(:millisecond) >= deadline, do: :deadline, else: :unreachable
  end

  defp transport(%Req.HTTPError{}, _deadline), do: {:malformed, :http}

  defp transport(exception, _deadline) do
    Logger.warning(
      "[Compendium.Builds.Client] the builds service was not reached: " <>
        Exception.message(exception)
    )

    :unreachable
  end

  defp new_line, do: %{private: %{}}
  defp max_response_bytes, do: BuilderProtocol.max_response_bytes()
  defp put_state(resp, state), do: %{resp | private: Map.put(resp.private, @state, state)}

  # `over` is how far past the answer's bound the bytes seen had run.
  defp too_large(over),
    do: {:malformed, {:response_too_large, max_response_bytes() + over, max_response_bytes()}}

  # ---------------------------------------------------------------------------
  # The result, verified
  # ---------------------------------------------------------------------------

  defp verify(%{language: language, target_type: type} = result, %{
         language: language,
         target_type: type
       }) do
    verify_outputs(language, result)
  end

  defp verify(%{language: language, target_type: type}, _wire),
    do: {:error, {:malformed, {:another_build, language, type}}}

  defp verify_outputs(:rust, %{outputs: outputs} = result) do
    wasm = Map.fetch!(outputs, BuilderProtocol.component_wasm())

    with {:ok, lockfile} <- lockfile(Map.get(outputs, BuilderProtocol.component_lockfile())),
         {:ok, validation} <- validate(wasm) do
      {:ok,
       result
       |> described()
       |> Map.merge(%{
         wasm_bytes: wasm,
         lockfile: lockfile,
         digest: validation.digest,
         size: validation.size,
         exports: validation.exports
       })}
    end
  end

  defp verify_outputs(:javascript, %{outputs: outputs} = result) do
    {digest, size} = Cyfr.Digest.file_set(outputs)

    {:ok,
     result
     |> described()
     |> Map.merge(%{output_files: outputs, digest: digest, size: size, exports: []})}
  end

  defp described(%{language: language, target_type: type, diagnostics: diagnostics}) do
    %{
      language: Atom.to_string(language),
      target_type: Atom.to_string(type),
      diagnostics: diagnostics
    }
  end

  defp validate(wasm) do
    case Compendium.WasmValidator.validate(wasm) do
      {:ok, validation} -> {:ok, validation}
      {:error, reason} -> {:error, {:malformed, {:invalid_wasm, reason}}}
    end
  end

  # The lock becomes one of the unit's sources, so it is held to what the
  # next build's request may carry.
  defp lockfile(nil), do: {:ok, nil}

  defp lockfile(lockfile) do
    max = BuilderProtocol.max_source_bytes()

    if byte_size(lockfile) <= max,
      do: {:ok, lockfile},
      else: {:error, {:malformed, {:lockfile_too_large, byte_size(lockfile), max}}}
  end
end
