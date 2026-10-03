# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.LayoutPublished do
  @moduledoc """
  A person's layout document was published, on `Cyfr.Bus.layouts/2` of
  that person (`user_id`): the revision it was published at (`revision`).
  Broadcast after the publish committed. The document itself does not
  travel: a subscriber reads the layout again under its own context.
  """

  alias Cyfr.Bus.Payload

  @kinds [:published]
  @fields []

  @enforce_keys [:athanor_id, :kind, :user_id, :revision]
  defstruct [:athanor_id, :kind, :user_id, :revision | @fields]

  @type kind :: :published

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          user_id: String.t(),
          revision: pos_integer()
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The payload for `actor`'s athanor: `user_id`'s layout published at `revision`."
  @spec new(Prima.Actor.t(), String.t(), pos_integer()) :: t()
  def new(%Prima.Actor{} = actor, user_id, revision)
      when is_binary(user_id) and user_id != "" and is_integer(revision) and revision > 0 do
    Payload.build(__MODULE__, @fields, %{}, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, :published, @kinds),
      user_id: user_id,
      revision: revision
    })
  end
end
