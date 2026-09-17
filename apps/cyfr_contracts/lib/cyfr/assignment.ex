# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Assignment do
  @moduledoc """
  What CYFR hands a worker to run one execution attempt, and what the
  runner presents to claim it (`c:Cyfr.HostAPI.attach/2`).

  `sign/2` JCS-encodes an assignment (`Cyfr.JCS`) and MACs the encoding with
  the assign key (`Cyfr.WorkerAuth.assign_key/1`). Only CYFR holds that key,
  so a worker cannot mint or alter an assignment. The token is
  `base64url(jcs) <> "." <> base64url(mac)`, both unpadded, and the same
  assignment always signs to the same token. An assignment `verify/3` would
  refuse as malformed does not sign: `sign/2` answers
  `{:error, :invalid_assignment}`.

  ## Fields (v1)

    * `v` — `1`.
    * `generation` — the control-plane generation it was issued under.
    * `service` — the id of the worker service it is dispatched to;
      `boot` — the boot of that worker service dispatch selected, which
      another boot of it refuses.
    * `issued_at`, `claim_by` — when it was issued, and the latest time a
      runner may claim it.
    * `execution_id`, `attempt`, `fence` — the attempt it runs.
    * `parent_execution_id` — the parent execution; nil for a root.
    * `root_execution_id` — the root of its execution tree.
    * `step` — the turn step that dispatched it, as its `id` and
      `generation`; nil when no turn step did.
    * `athanor_id` — the tenant.
    * `actor` — who it runs for (`Cyfr.Actor`).
    * `authority` — its authority as `Cyfr.Authority.to_wire/1`'s map, which
      `Cyfr.Authority.from_wire/1` must accept. The encoding carries no
      null: a member whose value is nil is omitted at any depth, so a
      verified assignment's authority lacks those members.
    * `component` — its `ref` (a canonical component reference,
      `Cyfr.ComponentRef`, of its `type`), its `type` (one of
      `Cyfr.ComponentRef.valid_types/0`), the `digest` of its artifact, the
      `declared_needs` its manifest names (at most 256, each a manifest need
      name: a lowercase letter, then up to 31 lowercase letters, digits,
      `_` or `-`), and its `activation_digest` (nil when it has none).
    * `input_digest` — `Cyfr.Digest.sha256/1` of the input bytes, which
      travel beside the assignment.
    * `timeout_ms` — the run's timeout; `deadline` — its subtree's deadline;
      `lease_until` — when its lease expires.
    * `intercepted` — the `tool.action` names the catalog annotates
      `host: :intercepted`, which a formula's host runs rather than the
      catalog: at most 256, each at most 256 bytes.

  Times are Unix milliseconds. Identifiers and component references are 1
  to 256 bytes of printable ASCII without spaces, and digests are `sha256:`
  followed by 64 lowercase hex digits.

  ## Verifying

  `verify/3` answers the assignment or the first refusal, in this order:

    1. `:malformed` — the token is not two unpadded base64url parts, the
       second a 32-byte MAC;
    2. `:bad_mac` — the MAC is not the assign key's over the payload;
    3. `:unknown_version` — the payload is an object whose `v` is an
       integer other than `1`;
    4. `:malformed` — the payload is not a v1 assignment: not a JSON
       object, or a member unknown, missing or of the wrong type, which is
       refused, never defaulted;
    5. `:claim_expired` — `now` is past `claim_by`.

  The rest of a claim is the caller's: that the service and boot are the
  presenting worker service's, that the generation is current, and that
  the attempt row is running at this fence and unclaimed.

  ## Reading

  A worker service holds no assign key, so it reads the assignment it is
  started with through `read/1`, which decodes the token's payload as
  `verify/3` does without checking its MAC or its claim deadline. What it
  answers authorizes nothing: CYFR verifies the token when the runner
  attaches.
  """

  alias Cyfr.Actor

  @enforce_keys [
    :generation,
    :service,
    :boot,
    :issued_at,
    :claim_by,
    :execution_id,
    :attempt,
    :fence,
    :root_execution_id,
    :athanor_id,
    :actor,
    :authority,
    :component,
    :input_digest,
    :timeout_ms,
    :deadline,
    :lease_until,
    :intercepted
  ]
  defstruct @enforce_keys ++ [v: 1, parent_execution_id: nil, step: nil]

  @typedoc "Unix milliseconds."
  @type time :: non_neg_integer()

  @type step :: %{id: String.t(), generation: non_neg_integer()}

  @type component :: %{
          ref: String.t(),
          type: String.t(),
          digest: String.t(),
          declared_needs: [String.t()],
          activation_digest: String.t() | nil
        }

  @type t :: %__MODULE__{
          v: 1,
          generation: pos_integer(),
          service: String.t(),
          boot: String.t(),
          issued_at: time(),
          claim_by: time(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          parent_execution_id: String.t() | nil,
          root_execution_id: String.t(),
          step: step() | nil,
          athanor_id: String.t(),
          actor: Actor.t(),
          authority: map(),
          component: component(),
          input_digest: String.t(),
          timeout_ms: pos_integer(),
          deadline: time(),
          lease_until: time(),
          intercepted: [String.t()]
        }

  @typedoc "A signed assignment."
  @type token :: String.t()

  @type refusal :: :malformed | :bad_mac | :unknown_version | :claim_expired

  @fields [
    v: :version,
    generation: :pos_integer,
    service: :id,
    boot: :id,
    issued_at: :time,
    claim_by: :time,
    execution_id: :id,
    attempt: :id,
    fence: :pos_integer,
    parent_execution_id: {:optional, :id},
    root_execution_id: :id,
    step: {:optional, :step},
    athanor_id: :id,
    actor: :actor,
    authority: :authority,
    component: :component,
    input_digest: :digest,
    timeout_ms: :pos_integer,
    deadline: :time,
    lease_until: :time,
    intercepted: :intercepted
  ]
  @wire_keys Enum.map(@fields, fn {name, _type} -> Atom.to_string(name) end)
  @component_keys ~w(ref type digest declared_needs activation_digest)

  @id ~r/\A[\x21-\x7E]{1,256}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @tool_action ~r/\A(?=.{3,256}\z)[a-z0-9_-]+\.[a-z0-9_-]+\z/
  @need ~r/\A[a-z][a-z0-9_-]{0,31}\z/
  @max_list 256

  @claim_window_ms 30_000

  @doc """
  How long after issue a runner may claim an assignment, in milliseconds:
  `claim_by` is `issued_at` plus this, and a `start` request that has not
  been answered within it is not retried but reconciled against the
  attempt's claim.
  """
  @spec claim_window_ms() :: pos_integer()
  def claim_window_ms, do: @claim_window_ms

  @doc "The token for `assignment`, MAC'd with the assign key."
  @spec sign(t(), binary()) :: {:ok, token()} | {:error, :invalid_assignment | Cyfr.JCS.error()}
  def sign(%__MODULE__{} = assignment, assign_key) when is_binary(assign_key) do
    wire = to_wire(assignment)

    with :ok <- decodable(wire),
         {:ok, payload} <- Cyfr.JCS.encode(wire) do
      {:ok, encode64(payload) <> "." <> encode64(mac(assign_key, payload))}
    end
  end

  @doc "The assignment a token carries, verified with the assign key at `now` (Unix ms)."
  @spec verify(term(), binary(), integer()) :: {:ok, t()} | {:error, refusal()}
  def verify(token, assign_key, now) when is_binary(assign_key) and is_integer(now) do
    with {:ok, payload, mac} <- split(token),
         :ok <- authentic(assign_key, payload, mac),
         {:ok, wire} <- json_object(payload),
         :ok <- known_version(wire),
         {:ok, assignment} <- decode(wire),
         :ok <- claimable(assignment, now) do
      {:ok, assignment}
    end
  end

  @doc """
  The assignment a token carries, without verifying its MAC or its claim
  deadline. Refused, as `verify/3` refuses them: `:malformed` and
  `:unknown_version`.
  """
  @spec read(term()) :: {:ok, t()} | {:error, :malformed | :unknown_version}
  def read(token) do
    with {:ok, payload, _mac} <- split(token),
         {:ok, wire} <- json_object(payload),
         :ok <- known_version(wire) do
      decode(wire)
    end
  end

  # ============================================================================
  # Token
  # ============================================================================

  defp split(token) when is_binary(token) do
    with [payload64, mac64] <- String.split(token, "."),
         {:ok, payload} <- Base.url_decode64(payload64, padding: false),
         {:ok, <<_::binary-size(32)>> = mac} <- Base.url_decode64(mac64, padding: false),
         ^token <- encode64(payload) <> "." <> encode64(mac) do
      {:ok, payload, mac}
    else
      _ -> {:error, :malformed}
    end
  end

  defp split(_token), do: {:error, :malformed}

  defp authentic(assign_key, payload, mac) do
    if :crypto.hash_equals(mac(assign_key, payload), mac), do: :ok, else: {:error, :bad_mac}
  end

  defp json_object(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = wire} -> {:ok, wire}
      _ -> {:error, :malformed}
    end
  end

  defp known_version(%{"v" => 1}), do: :ok
  defp known_version(%{"v" => v}) when is_integer(v), do: {:error, :unknown_version}
  defp known_version(_wire), do: {:error, :malformed}

  defp claimable(%__MODULE__{claim_by: claim_by}, now) when now <= claim_by, do: :ok
  defp claimable(_assignment, _now), do: {:error, :claim_expired}

  defp mac(key, payload), do: :crypto.mac(:hmac, :sha256, key, payload)
  defp encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  # ============================================================================
  # Wire
  # ============================================================================

  defp to_wire(assignment) do
    Enum.reduce(@fields, %{}, fn {name, type}, wire ->
      case write(type, Map.fetch!(assignment, name)) do
        nil -> wire
        value -> Map.put(wire, Atom.to_string(name), value)
      end
    end)
  end

  defp write({:optional, type}, value), do: write(type, value)
  defp write(:actor, %Actor{} = actor), do: Actor.to_wire(actor)
  defp write(:authority, %{} = authority), do: without_nil(authority)

  defp write(:step, %{id: id, generation: generation}),
    do: %{"id" => id, "generation" => generation}

  defp write(:component, %{ref: ref, type: type, digest: digest, declared_needs: needs} = c) do
    %{"ref" => ref, "type" => type, "digest" => digest, "declared_needs" => needs}
    |> without_nil_member("activation_digest", Map.get(c, :activation_digest))
  end

  defp write(_type, value), do: value

  defp without_nil(%{} = map) when not is_struct(map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {key, without_nil(value)})

  defp without_nil(list) when is_list(list), do: Enum.map(list, &without_nil/1)
  defp without_nil(value), do: value

  defp without_nil_member(map, _key, nil), do: map
  defp without_nil_member(map, key, value), do: Map.put(map, key, value)

  defp decodable(wire) do
    case decode(wire) do
      {:ok, _assignment} -> :ok
      {:error, :malformed} -> {:error, :invalid_assignment}
    end
  end

  defp decode(wire) do
    with [] <- Map.keys(wire) -- @wire_keys,
         {:ok, fields} <- read_fields(wire) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> {:error, :malformed}
    end
  end

  defp read_fields(wire) do
    Enum.reduce_while(@fields, {:ok, []}, fn {name, type}, {:ok, fields} ->
      case read_member(type, Map.fetch(wire, Atom.to_string(name))) do
        {:ok, value} -> {:cont, {:ok, [{name, value} | fields]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp read_member({:optional, _type}, :error), do: {:ok, nil}
  defp read_member({:optional, type}, {:ok, value}), do: read(type, value)
  defp read_member(_type, :error), do: :error
  defp read_member(type, {:ok, value}), do: read(type, value)

  defp read(:version, 1), do: {:ok, 1}
  defp read(:pos_integer, value) when is_integer(value) and value > 0, do: {:ok, value}
  defp read(:time, value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp read(:id, value) when is_binary(value), do: matching(@id, value)
  defp read(:digest, value) when is_binary(value), do: matching(@digest, value)

  defp read(:step, %{"id" => id, "generation" => generation} = step)
       when map_size(step) == 2 and is_integer(generation) and generation >= 0 do
    with {:ok, id} <- read(:id, id), do: {:ok, %{id: id, generation: generation}}
  end

  defp read(:actor, value) do
    case Actor.from_wire(value) do
      {:ok, actor} -> {:ok, actor}
      {:error, :invalid_actor} -> :error
    end
  end

  defp read(:authority, %{} = authority) when not is_struct(authority) do
    case Cyfr.Authority.from_wire(authority) do
      {:ok, _authority} -> {:ok, authority}
      {:error, _reason} -> :error
    end
  end

  defp read(:component, %{"ref" => ref, "declared_needs" => needs} = component)
       when is_binary(ref) and is_list(needs) and length(needs) <= @max_list do
    with [] <- Map.keys(component) -- @component_keys,
         true <- Map.get(component, "type") in Cyfr.ComponentRef.valid_types(),
         true <- canonical_ref?(ref, component["type"]),
         {:ok, digest} <- read(:digest, Map.get(component, "digest")),
         true <- Enum.all?(needs, &(is_binary(&1) and Regex.match?(@need, &1))),
         {:ok, activation_digest} <-
           read_member({:optional, :digest}, Map.fetch(component, "activation_digest")) do
      {:ok,
       %{
         ref: ref,
         type: component["type"],
         digest: digest,
         declared_needs: needs,
         activation_digest: activation_digest
       }}
    else
      _ -> :error
    end
  end

  defp read(:intercepted, names) when is_list(names) and length(names) <= @max_list do
    if Enum.all?(names, &(is_binary(&1) and Regex.match?(@tool_action, &1))),
      do: {:ok, names},
      else: :error
  end

  defp read(_type, _value), do: :error

  defp matching(regex, value), do: if(Regex.match?(regex, value), do: {:ok, value}, else: :error)

  # A reference names its component once, as `Cyfr.ComponentRef` spells it,
  # and of the type the assignment gives.
  defp canonical_ref?(ref, type) do
    with true <- Regex.match?(@id, ref),
         {:ok, %Cyfr.ComponentRef{type: ^type} = parsed} <- Cyfr.ComponentRef.parse(ref) do
      Cyfr.ComponentRef.to_string(parsed) == ref
    else
      _ -> false
    end
  end
end
