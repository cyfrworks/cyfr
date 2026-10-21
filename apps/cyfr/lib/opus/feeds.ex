# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Feeds do
  @moduledoc """
  An athanor's feeds: each binds one component operation, fixed arguments,
  an interval and labelled actions (`Prima.Feed.Binding`), and is a row of
  the schedules' table of kind `feed` whose id is its binding id
  (`Arca.CronSchedule`). The scheduler fires it as it fires a schedule
  (`Opus.Schedules.Scheduler`), and a result is kept only when this
  module accepts it.

    * The most live feeds an athanor holds is the platform setting
      `max_feeds_per_athanor` (0 is no ceiling), read at each bind and
      counted under the athanor's lock in the transaction that inserts a
      feed (`Arca.CronSchedule.create_feed/2`, which takes it as `cap:`),
      apart from the schedules' own.
    * `list/1` answers the caller's athanor's live feeds, each as
      `t:feed/0`, a row's stored binding read back through its grammar.
    * `accept/5` takes a run's output for the seq the run claimed: it
      checks the member's slot and the seq first, writing nothing, then
      decodes the output, unwraps its envelope, holds the data to the
      binding's result bound and shape (`Prima.Feed.check_result/2`) and
      writes its JSON text fenced (`Arca.CronSchedule.accept_feed_result/5`).
      A refused result writes nothing. An accepted one is answered as the
      envelope a feed's stream carries (`Prima.Feed.envelope/5`), built
      from the row the write committed.
    * `bind/2`, `remove/2` and `press/3` are the `feed` tool's writes
      (`Opus.Providers.Feed`), and `latest/2` is the refresh of its
      `feed.results` stream.

  ## Publication

  An accepted result is published on the athanor's one feeds topic
  (`Cyfr.Bus.feeds/1`, `Cyfr.Bus.FeedPublished`) by whoever accepted it,
  a press here or a fire in the scheduler, and only from the envelope a
  committed accept answered: a stale, refused or failed accept publishes
  nothing. A publish that fails is logged by the binding id and never
  undoes or retries the accept.

  ## A press

  A press names a binding id and one of its actions, and runs under the
  binding's own profile (`Opus.run_root/5`) within the call that asked
  for it, in the caller's context as it arrives: its origin is the one the
  caller's admission path set, never forced, and Prism's context carries
  `interactive` itself. An id that is no longer a live binding of the
  caller's athanor is `not_found`, so a control drawn for a binding
  removed or rebound since never presses the new one. A `refresh`
  claims a fresh seq and accepts the run's result as a fire does, and
  publishes it; a `run` runs its own operation of the binding's
  component, with the arguments the binding fixed, and publishes
  nothing. Only a person's press of a control Prism draws reaches it: the
  operation is external only, and a canvas's code has no verb that binds,
  changes or refreshes a feed.

  ## The envelope

  A run's output, a catalyst's or a formula's alike, is an envelope: a
  JSON object of exactly `status` (an integer) and `data`, or an object
  holding `error` (with `status` optional). A feed's result is the `data`
  of an envelope whose `status` is 200 to 299, and the binding's result
  shape describes that data. Every other output is refused with reason
  `"error"`, naming only its `status` when it carries an integer one: a
  status outside 2xx, an `error` envelope, an envelope with a key besides
  `status` and `data`, and an output that is no envelope at all. No output
  is taken as it is.

  A feed's arguments and results are JSON text, never digested; nothing
  here logs a result or a binding's content.
  """

  alias Arca.CronSchedule
  alias Cyfr.Bus.FeedPublished
  alias Prima.Feed.{Action, Binding}
  alias Sanctum.Consent.RegistrationBinding
  alias Sanctum.Context

  require Logger

  # The sentence of the reason `"error"`, which is this module's and not
  # one of `Prima.Feed.reasons/0`.
  @error_sentence "the operation answered an error, or no envelope"

  @typedoc """
  A live feed: its binding id, its binding, the seq and time of its
  accepted result (0 and nil before the first), and that result, decoded
  (nil before the first).
  """
  @type feed :: %{
          binding_id: String.t(),
          binding: Binding.t(),
          feed_result_seq: non_neg_integer(),
          feed_result_at: DateTime.t() | nil,
          result: term()
        }

  @typedoc """
  Why a result is refused: where in it, and the reason — one of
  `Prima.Feed.reasons/0`, or `"error"` for an output that is not a 2xx
  envelope, which also names the output's integer `status` when it has
  one, and nothing else of it.
  """
  @type refusal :: %{
          required(:path) => String.t(),
          required(:reason) => String.t(),
          optional(:status) => integer()
        }

  @doc """
  The sentence a refused result's reason reads as: `Prima.Feed.reasons/0`'s,
  and for `"error"`, an output that is not a 2xx envelope, "#{@error_sentence}".
  """
  @spec reason_sentence(String.t()) :: String.t()
  def reason_sentence("error"), do: @error_sentence

  def reason_sentence(reason) when is_binary(reason),
    do: Map.get(Prima.Feed.reasons(), reason, reason)

  @doc """
  Bind a feed in the caller's athanor from the `feed.bind` arguments, in
  this order:

    1. `reference` is resolved to its pinned installed version
       (`Compendium.resolve/2`); one not installed is `not_found`.
    2. The pinned version's manifest declares `results[operation]`, the
       shape of the operation's data, which the binding copies; an
       operation that declares none is `invalid_argument`.
    3. The binding holds (`Prima.Feed.Binding.validate/1`); a refusal is
       `invalid_argument` naming its pointer and reason, never a value.
    4. The caller may bind the profile to the pinned version
       (`Sanctum.Consent.RegistrationBinding.authorize/3`).
    5. The profile's head consent admits the `schedule` origin a fire runs
       under, or the bind answers the consent signal that raises the grant
       prompt for that profile.
    6. The row is created under the athanor's feed cap
       (`Arca.CronSchedule.create_feed/2`), and the scheduler is told.

  Answers the binding id, the feed's name, its label, its interval and
  its actions' names, labels and kinds, never its arguments.
  """
  @spec bind(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def bind(%Context{} = ctx, %{} = args) do
    reference = Map.get(args, "reference")
    profile_id = Map.get(args, "profile_id")

    with {:ok, pinned} <- resolve(ctx, reference),
         {:ok, shape} <- result_shape(ctx, pinned, reference, Map.get(args, "operation")),
         {:ok, binding} <- binding(args, shape),
         :ok <- authorize_profile(ctx, pinned, profile_id),
         :ok <- schedule_origin(ctx, profile_id),
         {:ok, row} <- create(ctx, binding, pinned, profile_id) do
      Opus.Schedules.Scheduler.add(row.id)

      {:ok,
       %{
         binding: row.id,
         feed: binding.name,
         label: binding.label,
         interval_minutes: binding.interval_minutes,
         actions: actions(binding)
       }}
    end
  end

  @doc """
  Remove the caller's athanor's live feed `binding_id` and tell the
  scheduler. An id that is not a live binding of the athanor is
  `not_found`; a fire in flight then finds the row gone at its accept and
  writes nothing.
  """
  @spec remove(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def remove(%Context{} = ctx, binding_id) when is_binary(binding_id) do
    case CronSchedule.remove_feed(Context.actor(ctx), binding_id) do
      {:ok, row} ->
        Opus.Schedules.Scheduler.remove(row.id)
        {:ok, %{removed: true, binding: row.id, feed: row.name}}

      {:error, reason} ->
        {:error, store_refusal(reason, binding_id)}
    end
  end

  @doc """
  Press action `action` of the caller's athanor's live feed `binding_id`
  (the moduledoc's "A press"). A `refresh` answers the binding, the action
  and the accepted revision; a `run` the binding, the action, the
  execution it ran as and its status, never its output. A refused result
  is named by its pointer and its reason's sentence, never its content,
  and a failed run answers the run's own refusal.
  """
  @spec press(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def press(%Context{} = ctx, binding_id, action)
      when is_binary(binding_id) and is_binary(action) do
    with {:ok, row, binding} <- live_binding(ctx, binding_id),
         {:ok, declared} <- declared_action(binding, action) do
      # Minted before the run, as the scheduler mints a fire's: the
      # execution the run is admitted as.
      execution_id = Prima.UUID7.execution_id()

      case declared do
        %Action{kind: :refresh} -> refresh(ctx, row, binding, declared, execution_id)
        %Action{kind: :run} -> run_action(ctx, row, declared, execution_id)
      end
    end
  end

  @doc """
  The refresh of the stream `feed.results` for the subject `name`: the
  caller's athanor's live feed of that name as the envelope of its last
  accepted result, or none when no live feed holds the name or it has no
  accepted result yet.
  """
  @spec latest(Context.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def latest(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, feeds} <- list(ctx) do
      case Enum.find(feeds, &(&1.binding.name == name)) do
        %{feed_result_seq: seq, feed_result_at: %DateTime{} = at} = feed when seq > 0 ->
          {:ok, [Prima.Feed.envelope(feed.binding_id, feed.binding, seq, at, feed.result)]}

        _none ->
          {:ok, []}
      end
    end
  end

  def latest(%Context{}, _name), do: {:ok, []}

  # A feed row's stored binding (`feed_spec`, never null on a feed row),
  # read back through its grammar: `{:ok, binding}`, or
  # `{:error, %{path, reason}}` for text that is not JSON (`"json"`) or
  # that the grammar refuses.
  @spec spec(map()) :: {:ok, Binding.t()} | {:error, refusal()}
  defp spec(%{feed_spec: text}) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, json} -> Binding.validate(json)
      {:error, :invalid_json} -> {:error, %{path: "", reason: "json"}}
    end
  end

  @doc """
  The caller's athanor's live feeds, by name. A row whose stored binding no
  longer reads is left out, and logged by its id and the refusal, never by
  its content.
  """
  @spec list(Context.t()) :: {:ok, [feed()]} | {:error, :no_athanor | :database_error}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- CronSchedule.list_feeds(Context.actor(ctx)) do
      {:ok, rows |> Enum.flat_map(&readable/1) |> Enum.sort_by(& &1.binding.name)}
    end
  end

  @doc """
  Accept a run's `output` as feed `binding_id`'s result for `seq`, the seq
  the run claimed (`Arca.CronSchedule.claim_feed_seq/2`) under `slot`, the
  member slot read when it was claimed.

  The checks run in one order: the slot, then the sequence, then the
  output's size and shape. The slot and the sequence are checked first,
  writing nothing (`Arca.CronSchedule.check_feed_acceptance/4`), so a
  member that lost its slot is answered `:not_owner` and an earlier seq
  `:stale` whatever the output holds. Then a binary output is decoded as
  JSON text, and a map or list is taken as the decoded value; anything
  else is not JSON. The decoded output must be a 2xx envelope (the
  moduledoc's), whose `data` is the result. The result is held to the
  binding's bound and shape (`Prima.Feed.check_result/2`) and written as
  its `Prima.Json.encode/1` text, fenced, the slot and the sequence checked
  again in the write's own transaction.

  Answers `{:ok, envelope}` once written, the envelope
  (`Prima.Feed.envelope/5`) of the row the write committed: its binding
  id, binding, accepted seq and time, and the result its text decodes to.
  Answers `{:error, :stale}` when a later-claimed
  result was already accepted; `{:error, {:refused, refusal}}` for an
  output that is not JSON (`"json"`) or not a 2xx envelope (`"error"`,
  with its `status` when it has one), or a result past its bound
  (`"size"`) or outside its shape, which writes nothing; and the storage
  layer's
  `:not_found` (a feed removed, a schedule's or another athanor's id),
  `:not_owner` (a member that lost its slot), `:unclaimed`, `:no_athanor`
  and `:database_error` as they are.
  """
  @spec accept(Context.t(), String.t(), integer(), term(), Arca.ControlPlane.slot() | :none) ::
          {:ok, map()}
          | {:error,
             :stale
             | {:refused, refusal()}
             | :not_found
             | :not_owner
             | :unclaimed
             | :no_athanor
             | :database_error}
  def accept(%Context{} = ctx, binding_id, seq, output, slot)
      when is_binary(binding_id) and is_integer(seq) do
    actor = Context.actor(ctx)

    with :ok <- CronSchedule.check_feed_acceptance(actor, binding_id, seq, slot),
         {:ok, row} <- CronSchedule.get_feed(actor, binding_id),
         {:ok, binding} <- stored_binding(row),
         {:ok, decoded} <- decoded(output),
         {:ok, result} <- unwrapped(decoded),
         {:ok, text} <- checked(binding, result),
         {:ok, written} <- CronSchedule.accept_feed_result(actor, binding_id, seq, text, slot) do
      {:ok,
       Prima.Feed.envelope(
         written.id,
         binding,
         written.feed_result_seq,
         written.feed_result_at,
         stored_result(written)
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Bind
  # ---------------------------------------------------------------------------

  defp resolve(ctx, reference) do
    case Compendium.resolve(ctx, reference) do
      {:ok, pinned, _metadata} -> {:ok, pinned}
      {:error, {:not_found, _what}} -> {:error, {:not_found, "Component", reference}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The shape of the operation's data, as the pinned version's manifest
  # declares it.
  defp result_shape(ctx, pinned, reference, operation) do
    case Compendium.inspect_component(ctx, pinned) do
      {:ok, row} ->
        case Prima.Manifest.decode_strict(Map.get(row, "manifest")) do
          {:ok, %{"results" => %{} = results}} when is_map_key(results, operation) ->
            {:ok, Map.fetch!(results, operation)}

          {:ok, _declares_none} ->
            {:error, {:invalid_argument, "#{operation} declares no result shape"}}

          {:error, :malformed_manifest} ->
            {:error, {:unavailable, "Component"}}
        end

      {:error, {:not_found, _what}} ->
        {:error, {:not_found, "Component", reference}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp binding(args, shape) do
    json = %{
      "name" => Map.get(args, "name"),
      "label" => Map.get(args, "label"),
      "reference" => Map.get(args, "reference"),
      "operation" => Map.get(args, "operation"),
      "args" => Map.get(args, "args"),
      "interval_minutes" => Map.get(args, "interval_minutes"),
      "result_shape" => shape,
      "actions" => Map.get(args, "actions")
    }

    case Binding.validate(json) do
      {:ok, binding} ->
        {:ok, binding}

      {:error, %{path: path, reason: reason}} ->
        {:error, {:invalid_argument, "#{path}: #{reason}"}}
    end
  end

  # Binding a feed to a profile mints a standing conduit for that
  # profile's authority, as binding a schedule does: the consent class
  # gates it, never a permission a wildcard key holds.
  defp authorize_profile(ctx, pinned, profile_id) do
    case RegistrationBinding.authorize(ctx, pinned, profile_id) do
      :ok -> :ok
      {:error, reason} -> {:error, RegistrationBinding.refusal(reason)}
    end
  end

  # A feed fires with the `schedule` origin: a profile whose head consent
  # does not admit it is asked to grant again, as the loader asks.
  defp schedule_origin(ctx, profile_id) do
    case Sanctum.Consent.head_consent(ctx, profile_id) do
      {:ok, %{admitted_origins: origins, revision: revision}} ->
        if :schedule in origins do
          :ok
        else
          {:error,
           {:consent_required,
            %{profile_id: profile_id, current_revision: revision, shape_diff: []}}}
        end

      {:error, :not_found} ->
        {:error, RegistrationBinding.refusal({:no_head_consent, profile_id})}

      {:error, :corrupt} ->
        {:error, RegistrationBinding.refusal({:head_corrupt, profile_id})}

      {:error, :unavailable} ->
        {:error, RegistrationBinding.refusal({:head_unavailable, profile_id})}

      {:error, :no_athanor} ->
        {:error, :no_athanor}
    end
  end

  # The cap is read at the bind and counted in the insert's own
  # transaction; a cap the store cannot answer refuses, with no fallback.
  defp create(ctx, binding, pinned, profile_id) do
    with {:ok, cap} <- feed_cap() do
      attrs = %{binding: binding, resolved_reference: pinned, profile_id: profile_id, cap: cap}
      created(CronSchedule.create_feed(Context.actor(ctx), attrs), binding, cap)
    end
  end

  defp feed_cap do
    case Arca.PlatformSettings.effective("max_feeds_per_athanor") do
      {:ok, cap} when is_integer(cap) and cap >= 0 -> {:ok, cap}
      {:error, :unavailable} -> {:error, {:unavailable, "Feeds"}}
    end
  end

  defp created(answer, binding, cap) do
    case answer do
      {:ok, row} ->
        {:ok, row}

      {:error, :feed_cap} ->
        {:error,
         %Prima.Refusal{
           class: :forbidden,
           reason: :feed_cap,
           message:
             "This athanor holds #{cap} live feeds, the most it may; " <>
               "remove one to bind another (feed_cap)"
         }}

      {:error, :conflict} ->
        {:error, {:conflict, "a live feed is named #{binding.name}"}}

      {:error, {:validation, errors}} ->
        {:error, {:invalid_argument, "the feed was not bound: " <> validation(errors)}}

      {:error, reason} when reason in [:not_owner, :no_athanor] ->
        {:error, reason}

      {:error, reason} when reason in [:not_found, :database_error] ->
        {:error, {:unavailable, "Feeds"}}
    end
  end

  defp validation(errors) do
    errors
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  # A binding's actions as a canvas and a person see them: never the
  # operation or arguments a `run` carries.
  defp actions(%Binding{actions: actions}) do
    Enum.map(actions, fn %Action{name: name, label: label, kind: kind} ->
      %{name: name, label: label, kind: Atom.to_string(kind)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Press
  # ---------------------------------------------------------------------------

  defp live_binding(ctx, binding_id) do
    case CronSchedule.get_feed(Context.actor(ctx), binding_id) do
      {:ok, row} ->
        case spec(row) do
          {:ok, binding} ->
            {:ok, row, binding}

          {:error, refusal} ->
            unreadable(row, refusal)
            {:error, {:not_found, "Feed", binding_id}}
        end

      {:error, reason} ->
        {:error, store_refusal(reason, binding_id)}
    end
  end

  defp declared_action(%Binding{actions: actions}, name) do
    case Enum.find(actions, &(&1.name == name)) do
      %Action{} = action -> {:ok, action}
      nil -> {:error, {:not_found, "Action", name}}
    end
  end

  # A refresh is a fire the person asked for: a fresh seq claimed under
  # the slot read before the run, the run's result accepted under both,
  # then published from the envelope the accept committed.
  defp refresh(ctx, row, binding, action, execution_id) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         {:ok, seq} <- claim(ctx, row.id),
         {:ok, result} <- run(ctx, row, Prima.Feed.input(binding), execution_id) do
      case accept(ctx, row.id, seq, result.output, slot) do
        {:ok, envelope} ->
          publish(ctx, envelope)
          {:ok, %{binding: row.id, action: action.name, revision: envelope["revision"]}}

        {:error, :stale} ->
          {:error, {:conflict, "a newer result of feed #{binding.name} was accepted"}}

        {:error, {:refused, refusal}} ->
          {:error, {:invalid_argument, refused(refusal)}}

        {:error, :not_owner} ->
          {:error, :not_owner}

        # Removed while the run ran: the binding the press named is gone.
        {:error, :not_found} ->
          {:error, {:not_found, "Feed", row.id}}

        {:error, _other} ->
          {:error, {:unavailable, "Feeds"}}
      end
    end
  end

  defp run_action(ctx, row, action, execution_id) do
    with {:ok, result} <- run(ctx, row, Prima.Feed.input(action), execution_id) do
      {:ok,
       %{
         binding: row.id,
         action: action.name,
         execution_id: execution_id,
         status: Atom.to_string(result.status)
       }}
    end
  end

  defp claim(ctx, binding_id) do
    case CronSchedule.claim_feed_seq(Context.actor(ctx), binding_id) do
      {:ok, seq} -> {:ok, seq}
      {:error, reason} -> {:error, store_refusal(reason, binding_id)}
    end
  end

  # The binding's pinned version under the binding's own profile, in the
  # caller's context.
  defp run(ctx, row, input, execution_id) do
    Opus.run_root(ctx, {:id, row.profile_id}, row.resolved_reference, input,
      execution_id: execution_id
    )
  end

  # Named by its pointer, its reason's sentence and any status, never by
  # the result.
  defp refused(%{path: path, reason: reason} = refusal) do
    status =
      case refusal do
        %{status: status} when is_integer(status) -> " (status #{status})"
        _none -> ""
      end

    "the result was refused at #{inspect(path)}: #{reason_sentence(reason)}#{status}"
  end

  defp store_refusal(:not_found, binding_id), do: {:not_found, "Feed", binding_id}
  defp store_refusal(reason, _binding_id) when reason in [:not_owner, :no_athanor], do: reason
  defp store_refusal(_unanswered, _binding_id), do: {:unavailable, "Feeds"}

  # After the accept committed, from the envelope it answered. A publish
  # that fails is said by the binding id and undoes nothing.
  defp publish(ctx, envelope) do
    actor = Context.actor(ctx)

    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.feeds(actor), FeedPublished.new(actor, envelope)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Opus.Feeds] feed #{envelope["binding"]}'s accepted result was not published: " <>
            inspect(reason)
        )
    end
  end

  # ---------------------------------------------------------------------------

  defp readable(row) do
    case spec(row) do
      {:ok, binding} ->
        [
          %{
            binding_id: row.id,
            binding: binding,
            feed_result_seq: row.feed_result_seq,
            feed_result_at: row.feed_result_at,
            result: stored_result(row)
          }
        ]

      {:error, refusal} ->
        unreadable(row, refusal)
        []
    end
  end

  defp stored_binding(row) do
    case spec(row) do
      {:ok, binding} ->
        {:ok, binding}

      {:error, refusal} ->
        unreadable(row, refusal)
        {:error, :not_found}
    end
  end

  # The line names the row and where its binding fails, never its text.
  defp unreadable(row, %{path: path, reason: reason}) do
    Logger.warning(
      "[Opus.Feeds] feed #{row.id} has a stored binding that does not read " <>
        "(#{reason} at #{inspect(path)}); it is left out"
    )
  end

  # Written only as accepted JSON text; text that does not decode is said
  # by its size and read as no result.
  defp stored_result(%{feed_result: nil}), do: nil

  defp stored_result(%{feed_result: text} = row) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, result} ->
        result

      {:error, :invalid_json} ->
        Logger.warning(
          "[Opus.Feeds] feed #{row.id} has a stored result that is not JSON " <>
            "(#{byte_size(text)} bytes)"
        )

        nil
    end
  end

  defp decoded(output) when is_binary(output) do
    case Prima.Json.decode(output) do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_json} -> not_json()
    end
  end

  defp decoded(output) when (is_map(output) and not is_struct(output)) or is_list(output),
    do: {:ok, output}

  defp decoded(_output), do: not_json()

  defp not_json, do: {:error, {:refused, %{path: "", reason: "json"}}}

  # The result is the `data` of a 2xx envelope of exactly `status` and
  # `data`. Anything else is refused as an error, named by its integer
  # `status` when it has one and by nothing else it holds.
  defp unwrapped(%{"status" => status, "data" => data} = envelope)
       when is_integer(status) and status in 200..299 and map_size(envelope) == 2,
       do: {:ok, data}

  defp unwrapped(%{"status" => status}) when is_integer(status),
    do: {:error, {:refused, %{path: "", reason: "error", status: status}}}

  defp unwrapped(_output), do: {:error, {:refused, %{path: "", reason: "error"}}}

  # The result's JSON text, once its bound and shape hold.
  defp checked(binding, result) do
    with :ok <- Prima.Feed.check_result(binding, result),
         {:ok, text} <- Prima.Json.encode(result) do
      {:ok, text}
    else
      {:error, %{path: _, reason: _} = refusal} -> {:error, {:refused, refusal}}
      {:error, :unencodable} -> not_json()
    end
  end
end
