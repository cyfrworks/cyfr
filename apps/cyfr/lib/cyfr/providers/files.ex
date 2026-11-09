# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.Files do
  @moduledoc """
  The stream `files.changes`: the person's recent files and the offers
  waiting for their answer, for a canvas to show, and nothing it could
  open or download by itself. It declares no tool; the files are the
  `file` tool's (`Arca.Providers.Files`).

  The declaration is the host's rather than the storage layer's because a
  stream's refresh is handed the subscriber's context (`CyfrWeb.SSE`),
  which Arca, beneath the identity domain, cannot read.

  The stream rides the athanor's files topic (`Cyfr.Bus.files/1`,
  `Cyfr.Bus.FileListed`); an athanor is one person's, so its grant reaches
  that person's files and offers alone. Every item is derived here, once,
  for the refresh (`listed/2`) and for the bridge's live items alike
  (`Cyfr.TelemetryBridge`): a live item is what the refresh would list for
  its record at that moment.

  | kind | the record | `id` | `name` | `changed_at` | enters, leaves |
  |---|---|---|---|---|---|
  | `file` | a settled file under `data/` (`Arca.ObjectRevisions`) | its path | its own name | its last settlement | written; deleted, it or a folder above it |
  | `offer` | an offer to the person, offered and unexpired (`Arca.FileOffers`) | the offer | its first file's name | made | offered; accepted, declined, withdrawn or expired |

  `type` is the named file's media type, as the download route serves it
  (`MIME.from_path/1`), and an offer's `from` its sender's name as a
  reader CYFR does not run may see it (`Sanctum.Tenancy.Users.public_name/1`).
  `removed` names what left by its `id`, every other field nil: an
  offer, a file, or a folder deleted whole, which takes every file at or
  under its path with it. A refresh lists the newest 20 files, newest
  first, then the waiting offers, oldest first. Under the delivery
  contract (`Compendium.Canvas.catalog/1`) an item is keyed by its `id`,
  and a removal reaches a canvas as a fresh picture (`reread`), since a
  folder takes every file under it and the next newest file takes a
  removed one's place.

  Only `data/` is listed: it is the folder the person fills, and every
  other folder holds a component's, AQUA's, a note's or a thread's own
  files, which their own pages and streams show. No field carries a
  file's contents, a download link or a person's identifier.
  """

  @behaviour Prima.Provider

  alias Prima.Canvas.Shape
  alias Sanctum.Context

  # A day: the longest a grant on the stream lives.
  @deadline_bound 86_400

  # Fifteen minutes: how long a picture stands before it is read again.
  # Each change is announced, so a read only mends one the bus lost.
  @stale_after 900

  # The files a refresh lists, newest first.
  @recent 20

  @typedoc "One item: every field of the stream's payload, with its kind."
  @type item :: %{
          optional(:revision) => non_neg_integer(),
          optional(:at) => DateTime.t(),
          kind: Cyfr.Bus.FileListed.kind(),
          id: String.t(),
          name: String.t() | nil,
          type: String.t() | nil,
          changed_at: DateTime.t() | nil,
          from: String.t() | nil
        }

  @impl true
  def service, do: "cyfr"

  @impl true
  def tools, do: []

  @impl true
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "Tool", tool}}

  @doc "The stream `files.changes` (the moduledoc's)."
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "files.changes",
        topic: :files,
        projection:
          ["kind", "id", "name", "type", "changed_at", "from"] ++
            Prima.Provider.Stream.delivery_fields(),
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(shape()),
        key: "id",
        removal: "removed",
        reread: ["removed"],
        stale_after: @stale_after,
        refresh: {__MODULE__, :listed}
      }
    ]
  end

  @doc """
  The refresh of `files.changes`: the athanor's newest files and, in the
  person's own athanor, the offers waiting for them, as the moduledoc's
  table derives them. A store that cannot answer ends the refresh with
  its reason.
  """
  @spec listed(Context.t(), nil) :: {:ok, [item()]} | {:error, term()}
  def listed(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, nil)
      when is_binary(athanor_id) and athanor_id != "" do
    actor = Context.actor(ctx)
    began = DateTime.utc_now()

    with {:ok, rows} <- Arca.ObjectRevisions.recent(actor, @recent),
         {:ok, offers} <- waiting(actor, user_id, []) do
      items = Enum.map(rows, &file_item(&1.path, &1.changed_at)) ++ offers
      {:ok, Enum.map(items, &Prima.Provider.Stream.stamped(&1, began))}
    end
  end

  def listed(%Context{}, _subject), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # One record's item, for the bridge's live events
  # ---------------------------------------------------------------------------

  @doc """
  What the path `path` (`data/` or a console path under it) names in the
  actor's athanor now: its file's item, or `removed` by the path when no
  file is settled there, a folder deleted whole among them.
  """
  @spec file(Prima.Actor.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def file(%Prima.Actor{} = actor, "data" <> _ = path) do
    case Arca.ObjectRevisions.changed_at(actor, String.split(path, "/")) do
      {:ok, changed_at} -> {:ok, [file_item(path, changed_at)]}
      {:error, :not_found} -> {:ok, [removed(path)]}
      {:error, _} = error -> error
    end
  end

  @doc """
  The offer `offer_id` to `recipient`, read in their own athanor (the
  actor's), while it waits for them; nothing once it does not.
  """
  @spec offer(Prima.Actor.t(), String.t(), String.t()) :: {:ok, [item()]} | {:error, term()}
  def offer(%Prima.Actor{} = actor, recipient, offer_id)
      when is_binary(recipient) and is_binary(offer_id),
      do: waiting(actor, recipient, offer_id: offer_id)

  @doc "The item that says `id` left the list."
  @spec removed(String.t()) :: item()
  def removed(id) when is_binary(id),
    do: %{kind: :removed, id: id, name: nil, type: nil, changed_at: nil, from: nil}

  # ---------------------------------------------------------------------------

  # The offers wait for their recipient in their own athanor, and nowhere
  # else they may stand.
  defp waiting(%Prima.Actor{athanor_id: athanor_id} = actor, user_id, opts)
       when is_binary(user_id) and user_id != "" do
    if Sanctum.Tenancy.Users.own_athanor?(user_id, athanor_id) do
      with {:ok, rows} <-
             Arca.FileOffers.awaiting(%{actor | user_id: user_id}, DateTime.utc_now(), opts) do
        {:ok, Enum.map(rows, &offer_item/1)}
      end
    else
      {:ok, []}
    end
  end

  defp waiting(_actor, _user_id, _opts), do: {:ok, []}

  defp file_item(path, changed_at) do
    name = path |> String.split("/") |> List.last()

    %{
      kind: :file,
      id: path,
      name: name,
      type: MIME.from_path(name),
      changed_at: changed_at,
      from: nil
    }
  end

  defp offer_item(row) do
    %{
      kind: :offer,
      id: row.offer_id,
      name: row.filename,
      type: MIME.from_path(row.filename),
      changed_at: row.inserted_at,
      from: Sanctum.Tenancy.Users.public_name(row.sender_user_id)
    }
  end

  defp shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{
          "type" => "enum",
          "values" => Enum.map(Cyfr.Bus.FileListed.kinds(), &Atom.to_string/1)
        },
        "id" => %{"type" => "string"},
        "name" => %{"type" => "string", "nullable" => true},
        "type" => %{"type" => "string", "nullable" => true},
        "changed_at" => %{"type" => "time", "nullable" => true},
        "from" => %{"type" => "string", "nullable" => true}
      },
      "required" => ["kind", "id", "name", "type", "changed_at", "from"]
    })
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Shape.validate(shape)
    normalized
  end
end
