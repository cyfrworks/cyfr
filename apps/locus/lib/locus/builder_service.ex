# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderService do
  @moduledoc """
  The builder container's HTTP face: one authenticated endpoint that runs
  `Locus.Builder.compile/3` and returns the artifact.

  Served only when `:cyfr, :builder_listen` is true — the `builder`
  release sets `CYFR_BUILDER_LISTEN=true`; the app image never listens.
  The client half is `Locus.BuilderClient`, selected by
  `CYFR_BUILDER_URL` on the server node.

  The contract is deliberately small: `POST /build` carries the source
  map (base64 values), the language and the target type; the response
  carries the compiled bytes (or a tincture's output files), the digest,
  and the build log lines. Progress cannot stream over one POST — the
  client replays the returned log lines to its own progress sink at
  completion. Auth is one static bearer (`CYFR_BUILDER_TOKEN`), compared
  constant-time; the compose network is internal-only on top.
  """

  use Plug.Router

  # Allow a 1 MiB source map with base64 overhead and envelope headroom.
  # Locus.Builder also validates and bounds decoded sources.
  @max_body_bytes 8_000_000

  plug(:match)
  # BEFORE the parser: the token rides a header, so an unauthenticated caller
  # is refused without the container reading — let alone JSON-parsing — up to
  # @max_body_bytes on their say-so. The build slot is taken later still, so
  # until this ran first the concurrency cap bounded toolchain processes but
  # not memory, on a port that binds 0.0.0.0.
  plug(:authenticate)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: @max_body_bytes)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{ok: true, toolchains: Locus.Builder.available_toolchains()})
  end

  # `/health` is the one route that answers without a token — it names the
  # toolchains and nothing else. Everything else must present one.
  defp authenticate(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    case check_token(conn) do
      :ok ->
        conn

      {:error, :unauthorized} ->
        conn
        |> send_json(401, %{ok: false, error: "unauthorized"})
        |> halt()
    end
  end

  post "/build" do
    with {:ok, source_files, language, target_type} <- decode_request(conn.body_params),
         # The cap is enforced on THIS side of the wire too: the client-side
         # limiter governs one app node, but two app nodes (or anything else
         # holding the token) could otherwise run unbounded concurrent
         # cargo builds in the one container sized for a couple.
         :ok <- acquire_slot() do
      try do
        run_build(conn, source_files, language, target_type)
      after
        Locus.BuildLimiter.release()
      end
    else
      {:error, :unauthorized} ->
        send_json(conn, 401, %{ok: false, error: "unauthorized"})

      {:error, :busy} ->
        send_json(conn, 429, %{
          ok: false,
          error: "builder at capacity (#{Locus.BuildLimiter.max_builds()} concurrent builds)"
        })

      {:error, message} when is_binary(message) ->
        send_json(conn, 400, %{ok: false, error: message})
    end
  end

  match _ do
    send_json(conn, 404, %{ok: false, error: "not found"})
  end

  defp check_token(conn) do
    expected = Application.get_env(:cyfr, :builder_token)

    with [<<"Bearer ", presented::binary>>] <- get_req_header(conn, "authorization"),
         true <- is_binary(expected) and expected != "",
         true <- Plug.Crypto.secure_compare(presented, expected) do
      :ok
    else
      # No token configured is a refusal too: an unauthenticated builder
      # is a remote code executor.
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_request(%{
         "source_files" => sources,
         "language" => language,
         "target_type" => target_type
       })
       when is_map(sources) and is_binary(language) and is_binary(target_type) do
    with {:ok, language} <-
           known(language, Enum.map(Locus.Builder.languages(), &Atom.to_string/1), "language"),
         # The roster, not a copy of it: `Compendium.Scaffold.validate_type/1`
         # reads the same source, and a hand-written list here would silently
         # refuse a fifth component kind the rest of the system had accepted.
         {:ok, target_type} <-
           known(target_type, Sanctum.ComponentRef.valid_types(), "target_type"),
         {:ok, decoded} <- decode_sources(sources) do
      {:ok, decoded, String.to_existing_atom(language), String.to_existing_atom(target_type)}
    end
  end

  defp decode_request(_), do: {:error, "source_files, language and target_type are required"}

  defp known(value, roster, field) do
    if value in roster, do: {:ok, value}, else: {:error, "unknown #{field}: #{value}"}
  end

  defp decode_sources(sources) do
    # The ceiling runs on ENCODED sizes, before any byte is decoded —
    # decode-then-check materialized the whole oversized map first.
    # Encoded base64 is 4/3 the decoded size; checking 4/3 × the ceiling
    # here admits everything the compile's exact decoded check will.
    encoded_total = sources |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))
    ceiling = div(Locus.Builder.max_source_bytes() * 4, 3) + 1024

    if encoded_total > ceiling do
      {:error,
       "sources exceed the #{Locus.Builder.max_source_bytes()} byte total ceiling " <>
         "(#{encoded_total} bytes encoded)"}
    else
      Enum.reduce_while(sources, {:ok, %{}}, fn
        {path, b64}, {:ok, acc} when is_binary(path) and is_binary(b64) ->
          case Base.decode64(b64) do
            {:ok, content} -> {:cont, {:ok, Map.put(acc, path, content)}}
            :error -> {:halt, {:error, "source #{path} is not valid base64"}}
          end

        {path, _}, _acc ->
          {:halt, {:error, "source #{inspect(path)} is malformed"}}
      end)
    end
  end

  # The service has no tenant identity — the client side already applied
  # the per-athanor cap; this is the container's own global ceiling.
  defp acquire_slot do
    Locus.BuildLimiter.acquire(Locus.BuildLimiter, nil)
  end

  defp run_build(conn, source_files, language, target_type) do
    log = :ets.new(:build_log, [:public])
    # [line_seq, bytes_retained] — the byte budget mirrors Locus.Builder's
    # own retained-output cap, so a chatty build cannot grow this table
    # without bound while its lines wait to be replayed.
    counter = :counters.new(2, [])
    max_log_bytes = Locus.Builder.max_port_output_bytes()

    on_progress = fn stage, message ->
      line = "#{stage}: #{message}"

      if :counters.get(counter, 2) < max_log_bytes do
        :counters.add(counter, 1, 1)
        :counters.add(counter, 2, byte_size(line))
        :ets.insert(log, {:counters.get(counter, 1), line})
      end

      :ok
    end

    result =
      Locus.Builder.compile(source_files, language,
        target_type: target_type,
        on_progress: on_progress
      )

    logs =
      log
      |> :ets.tab2list()
      |> Enum.sort()
      |> Enum.map(fn {_i, line} -> line end)

    :ets.delete(log)

    case result do
      {:ok, %{wasm_bytes: wasm_bytes} = built} ->
        send_json(conn, 200, %{
          ok: true,
          wasm_base64: Base.encode64(wasm_bytes),
          digest: built.digest,
          size: built.size,
          exports: built.exports,
          language: built.language,
          target_type: built.target_type,
          logs: logs
        })

      {:ok, %{output_files: files} = built} ->
        send_json(conn, 200, %{
          ok: true,
          output_files: Map.new(files, fn {path, content} -> {path, Base.encode64(content)} end),
          digest: built.digest,
          size: built.size,
          exports: built.exports,
          language: built.language,
          target_type: built.target_type,
          logs: logs
        })

      {:error, reason} ->
        send_json(conn, 422, %{ok: false, error: render_reason(reason), logs: logs})
    end
  end

  defp render_reason({:compilation_failed, exit_code, output}),
    do: "Compilation failed (exit #{exit_code}): #{output}"

  defp render_reason(:compilation_timeout), do: "Compilation timed out"

  defp render_reason({:toolchain_not_found, lang}),
    do: "Toolchain not found in the builder image: #{lang}"

  defp render_reason(reason), do: "Compilation error: #{inspect(reason)}"

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
