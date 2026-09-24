# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.Provider do
  @moduledoc """
  The `build` tool (`Prima.Provider`), under the `locus` service label:

  - `compile` — build a component by reference on the builds service,
    publish its output and register it (`Compendium.Builds.compile/3`);
    with `async`, answer a build id at once and carry the outcome on the
    build's row (`Compendium.Builds.start/3`)
  - `validate` — validate WASM bytes the caller supplies
  - `toolchains` — the toolchains the builds service reports
  - `status` — a started build's row

  A build's progress leaves from here: each step is a `Cyfr.Bus.Progress`
  on the build's topic and, when the build runs for an MCP request, on that
  request's (`Cyfr.Bus.broadcast_progress/2`), where the transport streams
  it to the caller.
  """

  @behaviour Prima.Provider

  alias Compendium.Builds
  alias Sanctum.Context

  @impl true
  def service, do: "locus"

  @impl true
  def tools do
    alias Prima.{Arg, Operation}

    [
      Operation.tool(
        [
          Operation.new(
            "build",
            "compile",
            "Compile build",
            [
              Arg.new("reference", :string,
                required: true,
                description:
                  "Component reference to compile, e.g. 'catalyst:local.my-api:0.1.0' (compile action)"
              ),
              Arg.new("async", :boolean,
                description:
                  "compile only: return a build_id immediately and run the build in the background; poll with action=status or subscribe to the build:<id> topic"
              ),
              Arg.new("build_id", :string,
                description:
                  "Build identifier — optional for compile (minted when absent), required for status"
              ),
              Arg.new("resolve", :boolean,
                description:
                  "compile only, Rust: resolve the crates afresh and keep the new Cargo.lock — needed after a dependency changes; otherwise a component with a Cargo.lock builds locked to it"
              )
            ],
            kind: :execute,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "build",
            "validate",
            "Validate build",
            [
              Arg.new("wasm_base64", :string,
                required: true,
                description: "Base64-encoded WASM binary (validate action)"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain]
          ),
          Operation.new("build", "toolchains", "Toolchains build", [],
            kind: :read,
            planes: [:external, :in_chain]
          ),
          Operation.new(
            "build",
            "status",
            "Status build",
            [
              Arg.new("build_id", :string,
                required: true,
                description:
                  "Build identifier — optional for compile (minted when absent), required for status"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :execute
          )
        ],
        description: "Compile components by reference and manage build toolchains",
        title: "Build"
      )
    ]
  end

  # Public (no permission): read-only introspection of the toolchains
  # builds run with. No user data and no side effect.
  @impl true
  def handle("build", %Context{} = _ctx, %{"action" => "toolchains"}), do: Builds.toolchains()

  # Public (no permission): stateless validation of bytes the caller
  # supplies; no server-side data is exposed. The base64 input is bounded
  # by the shared memory ceiling's spelling
  # (`Prima.Limits.default_max_memory_bytes/0`), so the two cannot drift
  # apart, and since decoding and walking the bytes is real CPU no build
  # accounts for, each caller identity has a rate, the anonymous public
  # sharing one.
  @max_base64_size Prima.Limits.default_max_memory_bytes()
  @validate_per_minute 10

  def handle("build", %Context{} = ctx, %{"action" => "validate", "wasm_base64" => wasm_base64})
      when is_binary(wasm_base64) do
    with :ok <- check_validate_rate(ctx) do
      validate(wasm_base64)
    end
  end

  def handle("build", _ctx, %{"action" => "validate"}) do
    {:error, {:invalid_argument, "Missing required argument: wasm_base64"}}
  end

  def handle("build", %Context{} = ctx, %{"action" => "compile", "reference" => reference} = args)
      when is_binary(reference) do
    opts = [
      build_id: args["build_id"],
      resolve: args["resolve"] == true,
      on_progress: &send_progress(ctx, &1)
    ]

    if args["async"] == true,
      do: Builds.start(ctx, reference, opts),
      else: Builds.compile(ctx, reference, opts)
  end

  def handle("build", %Context{} = ctx, %{"action" => "status", "build_id" => build_id})
      when is_binary(build_id),
      do: Builds.status(ctx, build_id)

  def handle("build", _ctx, %{"action" => "status"}) do
    {:error, {:invalid_argument, "Missing required argument: build_id"}}
  end

  def handle("build", _ctx, %{"action" => "compile"}) do
    {:error, {:invalid_argument, "Missing required argument: reference"}}
  end

  def handle("build", _ctx, %{"action" => action}) do
    {:error,
     {:invalid_argument,
      "Invalid build action: #{action}. Use: compile, validate, toolchains, or status"}}
  end

  def handle("build", _ctx, _args) do
    {:error, {:invalid_argument, "Missing required argument: action"}}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  defp validate(wasm_base64) do
    if byte_size(wasm_base64) > @max_base64_size do
      {:error,
       {:invalid_argument,
        "Input too large: #{byte_size(wasm_base64)} bytes exceeds #{@max_base64_size} byte limit"}}
    else
      case Base.decode64(wasm_base64) do
        {:ok, bytes} ->
          case Prima.Wasm.validate(bytes) do
            {:ok, meta} ->
              {:ok,
               %{
                 valid: true,
                 digest: meta.digest,
                 size: meta.size,
                 exports: meta.exports,
                 suggested_type: to_string(meta.suggested_type)
               }}

            {:error, reason} ->
              {:ok, %{valid: false, reason: validation_failure(reason)}}
          end

        :error ->
          {:error, {:invalid_argument, "Invalid base64 encoding"}}
      end
    end
  end

  # A refusal's tag, as the builder names it: a tuple reason carries the
  # binary's own bytes or sizes after its tag, and only the tag is the
  # answer.
  defp validation_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp validation_failure(reason) when is_tuple(reason), do: inspect(elem(reason, 0))

  defp check_validate_rate(ctx) do
    who = ctx.user_id || ctx.athanor_id || "public"

    case Prima.RateLimiter.check("build:validate:#{who}", @validate_per_minute, 60_000) do
      :ok -> :ok
      {:deny, retry_s} -> {:error, "Validation rate limit reached — retry in #{retry_s}s"}
    end
  end

  # The console follows the build's topic; an MCP caller that asked for
  # progress follows its request's. Neither failing fails the build.
  defp send_progress(ctx, %{build_id: build_id, phase: phase, message: message}) do
    actor = Context.actor(ctx)

    step =
      Cyfr.Bus.Progress.new(actor, {:build, build_id},
        request_id: ctx.request_id,
        phase: phase,
        message: message
      )

    _ = Cyfr.Bus.broadcast_progress(actor, step)
    :ok
  end
end
