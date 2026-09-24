# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.Storage do
  @moduledoc """
  The host calls a runner makes for what its guest reaches beside its
  attempt's lifecycle: `storage`, `fetch_artifact` and `record_denial`
  (`Crucible.Host`).

  `operation/2` reads a call's arguments into an operation, and
  `Crucible.Attempt` runs it with `run/2` once the call is checked,
  in its own process, so an operation and the attempt's close never
  interleave. Everything an operation acts for — the athanor, the edge, the
  limits, the component and its digest — is the attempt's, never the
  call's.

  | Operation | `args` | `ok` |
  |---|---|---|
  | `storage` | `action` (`read`, `write`, `append`, `list`, `delete`, `exists`), `path`, optional `content` | the answer's members (`Crucible.GuestStorage`) |
  | `fetch_artifact` | `digest` | the artifact's bytes, base64 |
  | `record_denial` | `type`, `message` | `true` |

  `storage` refuses with `guest_error`. A write, append or delete runs
  under the attempt's hold as `Arca.ExecutionAttempts.while_held/5`
  specifies: one the attempt does not hold its row for is `lost` and
  touches nothing; one whose attempt lost its row while the store call was
  in flight, or whose store could not say what it did, is the
  `storage_uncertain` guest error, never `written` and never `lost`.
  `fetch_artifact` names only the digest of the attempt's
  own component; any other digest, and bytes the store does not hold or
  that do not match it, are `not_found`. `record_denial` records a
  policy-driven egress denial of the attempt's component
  (`Sanctum.Policy.Enforcement.record/1`), audits a `secret_denied` one as
  `[:cyfr, :opus, :secret, :denied]` with the field name its guest asked
  for, and ignores any other refusal type. A denial is attributed to the
  attempt the call was checked against, under the identity it was
  admitted with, whatever the runner sent; a `secret_denied` whose name is
  no field name (`Prima.HostAPI.valid_field_name?/1`) is `lost` and
  audits nothing.
  """

  require Logger

  alias Crucible.{Artifacts, GuestStorage}

  @actions %{
    "read" => :read,
    "write" => :write,
    "append" => :append,
    "list" => :list,
    "delete" => :delete,
    "exists" => :exists
  }

  # The runner's refusal types that are policy decisions, by the audit
  # event each is recorded as.
  @denials %{
    "domain_blocked" => :domain_blocked,
    "method_blocked" => :method_blocked,
    "scheme_blocked" => :scheme_blocked,
    "request_too_large" => :request_size,
    "response_too_large" => :request_size,
    "private_ip_blocked" => :denied,
    "rate_limited" => :denied
  }

  # A denial's message is the runner's sentence, kept to this many
  # characters.
  @message_max 1_024

  @typedoc "An operation of this module, read from a host call's arguments."
  @type op ::
          {:storage, GuestStorage.op(), map()}
          | {:fetch_artifact, String.t()}
          | {:record_denial, %{type: String.t(), message: String.t()}}

  @typedoc """
  What the attempt runs an operation with: its guest-plane context, its
  admission context, its authority, its node's limits, its component's
  reference and digest, the identity an audit entry of it carries (its
  athanor and person, execution, attempt, fence, component, consent,
  claiming runner and worker service) and its hold on its row
  (`t:Crucible.GuestStorage.hold/0`).
  """
  @type attempt :: %{
          ctx: Sanctum.Context.t(),
          admission_ctx: Sanctum.Context.t(),
          authority: Prima.Authority.t(),
          limits: Prima.Limits.t() | nil,
          component_ref: String.t(),
          digest: String.t() | nil,
          audit: map(),
          hold: GuestStorage.hold()
        }

  @doc "Read the operation `name` with its wire `args`; `{:error, :lost}` for anything malformed."
  @spec operation(String.t(), map()) :: {:ok, op()} | {:error, :lost}
  def operation("storage", %{"action" => action, "path" => path} = args)
      when is_map_key(@actions, action) and is_binary(path) do
    content = Map.get(args, "content")

    if is_nil(content) or is_binary(content),
      do: {:ok, {:storage, Map.fetch!(@actions, action), Map.take(args, ["path", "content"])}},
      else: {:error, :lost}
  end

  def operation("fetch_artifact", %{"digest" => digest}) when is_binary(digest),
    do: {:ok, {:fetch_artifact, digest}}

  def operation("record_denial", %{"type" => "secret_denied", "message" => name}) do
    if Prima.HostAPI.valid_field_name?(name),
      do: {:ok, {:record_denial, %{type: "secret_denied", message: name}}},
      else: {:error, :lost}
  end

  def operation("record_denial", %{"type" => type, "message" => message})
      when is_binary(type) and is_binary(message),
      do: {:ok, {:record_denial, %{type: type, message: message}}}

  def operation(_name, _args), do: {:error, :lost}

  @doc """
  Run `op` for `attempt`. Answers `{:ok, value}` or `:ok` as the table
  above, or `{:error, refusal}`.
  """
  @spec run(op(), attempt()) ::
          :ok
          | {:ok, term()}
          | {:error, :lost | :unavailable | :not_found | {:guest_error, String.t(), String.t()}}
  def run({:storage, action, args}, attempt) do
    attempt.ctx
    |> GuestStorage.scope(attempt.authority, attempt.limits, attempt.hold)
    |> GuestStorage.run(action, args)
  end

  def run({:fetch_artifact, digest}, %{digest: digest} = attempt) when is_binary(digest) do
    case Artifacts.fetch(attempt.admission_ctx, digest, attempt.component_ref) do
      {:ok, bytes} ->
        {:ok, Base.encode64(bytes)}

      {:error, reason} ->
        Logger.error(
          "[Crucible.Host.Storage] artifact #{digest} of #{attempt.component_ref} " <>
            "not fetched: #{inspect(reason)}"
        )

        {:error, :not_found}
    end
  end

  def run({:fetch_artifact, _digest}, attempt) do
    Logger.warning(
      "[Crucible.Host.Storage] refused an artifact that is not #{attempt.component_ref}'s"
    )

    {:error, :not_found}
  end

  def run({:record_denial, %{type: "secret_denied", message: name}}, attempt) do
    :telemetry.execute(
      [:cyfr, :opus, :secret, :denied],
      %{system_time: System.system_time()},
      Map.put(attempt.audit, :field, name)
    )
  end

  def run({:record_denial, %{type: type, message: message}}, attempt) do
    case Map.fetch(@denials, type) do
      {:ok, event_type} ->
        Sanctum.Policy.Enforcement.record(%{
          ctx: attempt.ctx,
          component_ref: attempt.component_ref,
          component_type: :catalyst,
          event_type: event_type,
          decision: :denied,
          decision_reason: String.slice(message, 0, @message_max)
        })

      :error ->
        :ok
    end
  end
end
