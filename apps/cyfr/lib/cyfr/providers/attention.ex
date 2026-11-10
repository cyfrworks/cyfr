# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.Attention do
  @moduledoc """
  The stream `attention.changes`: what waits for one person, for a canvas
  to show, and nothing it could act on by itself. It declares no tool.

  The stream rides the person's own attention topic
  (`Cyfr.Bus.attention/2`, `Cyfr.Bus.Attention`) and is bound to its
  holder, so a grant reaches that person's items alone. Every item
  references a record its owner keeps, and is derived from that record
  here, once, for the refresh (`waiting/2`) and for the bridge's live
  items alike (`Cyfr.TelemetryBridge`): a live item is what the refresh
  would list for the record at that moment. There is no record of
  attention of its own.

  | kind | the record | `id` | `label` | `since` | enters, leaves |
  |---|---|---|---|---|---|
  | `approval` | a pending approval in the athanor's threads | the approval | its thread's title | opened | opened; resolved or expired |
  | `grant_request` | a frame's request of the person, waiting in the shell that presents it (`Cyfr.Requests`) | the request | the operation it asks for, or the component a grant names | asked | asked; decided, expired, or withdrawn with its frame |
  | `confirmation` | the person's open confirmation of a sensitive change | its ref | its operation | opened | opened; consumed, cancelled, voided or expired |
  | `failed_run` | the newest failed top-level run of a reference the person ran, that no later run of it ended after | the reference | the reference | its end | failed; the reference's next top-level run's end |
  | `failed_schedule` | a schedule of the person whose latest ended occurrence failed or is uncertain | the schedule | its name | that occurrence's due time | failed; its next completed run or its deletion |
  | `file_offer` | an offer to the person, offered and unexpired | the offer | its first file's name | made | offered; accepted, declined, withdrawn or expired |

  A failed run is one item per reference, its `id` the exact reference the
  run's record keeps, so the next end of a run of that reference names
  the item it settles without a read. `removed` names the item that
  stopped waiting by its `id` and how it left by its `outcome`, every
  other field nil: `expired` for an end whose time ran out, `withdrawn`
  for a voided confirmation, a withdrawn offer, a deleted schedule or a
  deleted thread's approval, and `resolved` for every other end. A
  waiting item's `outcome` is nil. An approval that a
  cancel, a pause or an archive of its turn invalidates is announced to
  no one (`Arca.TurnStorage`), so it leaves at the next refresh, which
  the delivery contract (`Compendium.Canvas.catalog/1`) makes within five
  minutes: an item is keyed by its `id`.

  An athanor is one person's, so its threads' approvals wait for its
  owner, and an offer waits for its recipient in their own athanor; a
  run, a schedule, a confirmation and a request wait for the person their
  record names. Nothing an operator decides for the server is an item.

  The destination is where the person acts on the item, in one trusted
  spelling: `{kind: "page", page, ref}` for where Prism shows it, each a
  page a canvas opens with `settings` (`aqua`, AQUA's panel on the desktop,
  whose threads hold the approvals; the Dashboard's `executions`,
  `schedules` and `files`), and the record there (a thread, a run, a
  schedule or an offer), or `{kind: "ref", page: nil,
  ref}` for a confirmation, which the system layer presents wherever the
  person is, and for a request, which the system layer presents above
  the frame that asked. No field carries a message, a credential, a
  diagnostic sentence or a person's identifier.
  """

  @behaviour Prima.Provider

  alias Prima.Canvas.Shape
  alias Sanctum.Context

  # A day: the longest a grant on the stream lives.
  @deadline_bound 86_400

  # Five minutes: how long a picture stands before it is read again, the
  # bound on an approval that left untold (the moduledoc's).
  @stale_after 300

  # The failed runs a refresh lists, newest first.
  @failed_runs 20

  @pages ~w(aqua executions schedules files)

  @typedoc "One waiting item: the stream's payload fields with its kind."
  @type item :: %{
          optional(:revision) => non_neg_integer(),
          optional(:at) => DateTime.t(),
          kind: Cyfr.Bus.Attention.kind(),
          id: String.t(),
          label: String.t() | nil,
          since: DateTime.t() | nil,
          destination: map() | nil,
          outcome: nil
        }

  @impl true
  def service, do: "cyfr"

  @impl true
  def tools, do: []

  @impl true
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "Tool", tool}}

  @doc "The stream `attention.changes` (the moduledoc's)."
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "attention.changes",
        topic: :attention,
        projection:
          ["kind", "id", "label", "since", "destination", "outcome"] ++
            Prima.Provider.Stream.delivery_fields(),
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(shape()),
        refresh: {__MODULE__, :waiting},
        key: "id",
        removal: "removed",
        stale_after: @stale_after
      }
    ]
  end

  @doc """
  The refresh of `attention.changes`: everything waiting for the holder in
  the context's athanor, oldest first, as the moduledoc's table derives
  it. The approvals and the offers are listed only in the holder's own
  athanor, where they are told live. A store that cannot answer ends the
  refresh with its reason.
  """
  @spec waiting(Context.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def waiting(%Context{athanor_id: athanor_id, user_id: holder} = ctx, holder)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(holder) do
    actor = Context.actor(ctx)
    now = DateTime.utc_now()
    own? = Sanctum.Tenancy.Users.own_athanor?(holder, athanor_id)

    with {:ok, confirmations} <- Sanctum.Consent.waiting_confirmations(ctx),
         {:ok, approvals} <- if(own?, do: approvals(actor, now, []), else: {:ok, []}),
         {:ok, offers} <- if(own?, do: offers(actor, now, []), else: {:ok, []}),
         {:ok, runs} <- runs(actor, holder, limit: @failed_runs),
         {:ok, schedules} <- schedules(actor, holder, []) do
      items =
        Enum.map(confirmations, &confirmation/1) ++
          Cyfr.Requests.waiting(athanor_id, holder) ++ approvals ++ offers ++ runs ++ schedules

      {:ok,
       items
       |> Enum.sort_by(& &1.since, DateTime)
       |> Enum.map(&Prima.Provider.Stream.stamped(&1, now))}
    end
  end

  def waiting(%Context{athanor_id: athanor_id}, _holder)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:error, :not_holder}

  def waiting(%Context{}, _holder), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # One record's item, for the bridge's live events
  # ---------------------------------------------------------------------------

  @doc """
  The person an athanor's own items wait for: its owner, or `:none` for an
  athanor that does not read.
  """
  @spec person(String.t()) :: {:ok, String.t()} | :none
  def person(athanor_id) when is_binary(athanor_id) do
    case Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, %{owner_user_id: owner}} when is_binary(owner) and owner != "" -> {:ok, owner}
      _none -> :none
    end
  end

  @doc """
  The person's own athanor, where an item that reaches them from another
  athanor (an offer) is told, or `:none` for a person who holds none here.
  """
  @spec own_athanor(String.t()) :: {:ok, String.t()} | :none
  def own_athanor(user_id) when is_binary(user_id) do
    case Sanctum.Tenancy.Athanors.get_by_owner(user_id) do
      {:ok, %{id: id}} when is_binary(id) -> {:ok, id}
      _none -> :none
    end
  end

  @doc "The approval `approval_id` of the actor's athanor, while it waits."
  @spec approval(Prima.Actor.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def approval(%Prima.Actor{} = actor, approval_id) when is_binary(approval_id),
    do: approvals(actor, DateTime.utc_now(), approval_id: approval_id)

  @doc "The offer `offer_id` to the actor's person, while it waits for them."
  @spec file_offer(Prima.Actor.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def file_offer(%Prima.Actor{} = actor, offer_id) when is_binary(offer_id),
    do: offers(actor, DateTime.utc_now(), offer_id: offer_id)

  @doc "The failed run of `reference` by `user_id` in the actor's athanor, while it stands."
  @spec failed_run(Prima.Actor.t(), String.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def failed_run(%Prima.Actor{} = actor, user_id, reference)
      when is_binary(user_id) and is_binary(reference),
      do: runs(actor, user_id, reference: reference, limit: 1)

  @doc "The schedule `schedule_id` of `user_id` in the actor's athanor, while it is failing."
  @spec failed_schedule(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [item()]} | {:error, term()}
  def failed_schedule(%Prima.Actor{} = actor, user_id, schedule_id)
      when is_binary(user_id) and is_binary(schedule_id),
      do: schedules(actor, user_id, schedule_id: schedule_id)

  @doc """
  An open confirmation's item, from its `ref`, `operation` and `opened_at`
  (`Sanctum.Consent.waiting_confirmations/1`'s row, or its announcement).
  """
  @spec confirmation(%{ref: String.t(), operation: String.t(), opened_at: DateTime.t()}) ::
          item()
  def confirmation(%{ref: ref, operation: operation, opened_at: opened_at}) do
    %{
      kind: :confirmation,
      id: ref,
      label: operation,
      since: opened_at,
      destination: %{kind: "ref", page: nil, ref: ref},
      outcome: nil
    }
  end

  # ---------------------------------------------------------------------------

  defp approvals(actor, now, opts) do
    with {:ok, rows} <- Arca.TurnStorage.waiting_approvals(actor, now, opts) do
      {:ok,
       for row <- rows do
         item(:approval, row.id, row.title, row.inserted_at, page("aqua", row.thread_id))
       end}
    end
  end

  defp offers(actor, now, opts) do
    with {:ok, rows} <- Arca.FileOffers.awaiting(actor, now, opts) do
      {:ok,
       for row <- rows do
         item(
           :file_offer,
           row.offer_id,
           row.filename,
           row.inserted_at,
           page("files", row.offer_id)
         )
       end}
    end
  end

  defp runs(actor, user_id, opts) do
    with {:ok, rows} <- Arca.Execution.unresolved_failures(actor, user_id, opts) do
      {:ok,
       for row <- rows do
         item(
           :failed_run,
           row.reference,
           row.reference,
           row.completed_at,
           page("executions", row.id)
         )
       end}
    end
  end

  defp schedules(actor, user_id, opts) do
    with {:ok, rows} <- Arca.ScheduleOccurrences.failing(actor, user_id, opts) do
      {:ok,
       for row <- rows do
         item(:failed_schedule, row.id, row.name, row.scheduled_for, page("schedules", row.id))
       end}
    end
  end

  defp item(kind, id, label, since, destination),
    do: %{
      kind: kind,
      id: id,
      label: label,
      since: since,
      destination: destination,
      outcome: nil
    }

  defp page(page, ref) when page in @pages, do: %{kind: "page", page: page, ref: ref}

  defp shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{
          "type" => "enum",
          "values" => Enum.map(Cyfr.Bus.Attention.kinds(), &Atom.to_string/1)
        },
        "id" => %{"type" => "string"},
        "label" => %{"type" => "string", "nullable" => true},
        "since" => %{"type" => "time", "nullable" => true},
        "destination" => %{
          "type" => "object",
          "nullable" => true,
          "fields" => %{
            "kind" => %{"type" => "enum", "values" => ["page", "ref"]},
            "page" => %{"type" => "enum", "values" => @pages, "nullable" => true},
            "ref" => %{"type" => "string", "nullable" => true}
          },
          "required" => ["kind", "page", "ref"]
        },
        "outcome" => %{
          "type" => "enum",
          "values" => Enum.map(Cyfr.Bus.Attention.outcomes(), &Atom.to_string/1),
          "nullable" => true
        }
      },
      "required" => ["kind", "id", "label", "since", "destination", "outcome"]
    })
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Shape.validate(shape)
    normalized
  end
end
