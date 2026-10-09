# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.FeedPublished do
  @moduledoc """
  A feed's result was accepted, on `Cyfr.Bus.feeds/1` of its athanor:
  the envelope `Prima.Feed.envelope/5` built from the row the accept
  wrote — the binding id (`binding`), the feed's name (`feed`), the
  accepted seq (`revision`), when it was accepted (`at`, ISO 8601), the
  result, and the binding's display part (`label`, and `actions` as
  `[%{"name", "label"}]`). It never carries the binding's operation,
  arguments or reference. Broadcast only after the accept committed.
  """

  alias Cyfr.Bus.Payload

  @kinds [:published]
  @fields []

  @enforce_keys [:athanor_id, :kind, :binding, :feed, :revision, :at, :result, :label, :actions]
  defstruct @enforce_keys

  @type kind :: :published

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          binding: String.t(),
          feed: String.t(),
          revision: non_neg_integer(),
          at: String.t(),
          result: term(),
          label: String.t(),
          actions: [%{String.t() => String.t()}]
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor, from a feed's envelope
  (`Prima.Feed.envelope/5`): exactly its seven fields. Anything else, an
  envelope missing one among them, raises an `ArgumentError` naming no
  value, since a match error would print the envelope and its result.
  """
  @spec new(Prima.Actor.t(), map()) :: t()
  def new(
        %Prima.Actor{} = actor,
        %{
          "binding" => binding,
          "feed" => feed,
          "revision" => revision,
          "at" => at,
          "result" => result,
          "label" => label,
          "actions" => actions
        }
      ) do
    Payload.build(__MODULE__, @fields, %{}, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, :published, @kinds),
      binding: binding,
      feed: feed,
      revision: revision,
      at: at,
      result: result,
      label: label,
      actions: actions
    })
  end

  def new(_actor, _envelope),
    do: raise(ArgumentError, "new/2 takes an actor and a feed's envelope (Prima.Feed.envelope/5)")
end
