# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.GuestError do
  @moduledoc """
  The sentence a runner hands its guest for a refusal, rendered from data
  alone.

  A refusal reaches a runner over the wire as an answer
  (`Prima.WorkerWire`): a guest error's `type` and `message`, a `failed`
  message, a `setup_required` payload, or a refusal of the one vocabulary.
  This renders those, the `Prima.HostAPI` tuples a host client answers them
  as, and the reasons a runner produces itself, through `Prima.Refusal`'s
  table. Nothing here names a product module: a sentence CYFR wants a
  guest to see crosses the wire already rendered.

  What a refusal *means* is `Prima.Refusal`'s, and this module holds no
  sentence of its own for one. That is the whole point: a guest in a chain
  and a person at the console are told the same thing, because there is
  one place the thing is said. Before, two vocabularies restated each
  other and seven refusals were in only one of them — `:busy`,
  `:not_member`, `:archived`, `:no_agent`, `:control_plane_lost`,
  `:not_provisioned`, `:message_too_long` — so a guest hitting any of them
  was handed the atom's own name where a sentence belonged.

  `render/1` answers `nil` for a term it does not know, so a caller logs
  the term where it was produced and hands the guest a generic sentence
  instead of `inspect/1`'s spelling of it. An unrecognised atom is such a
  term: an internal name is not a sentence, and echoing it is how internal
  vocabulary reaches a guest-visible surface.
  """

  @doc "The client-safe sentence for `reason`, or `nil` for a term this vocabulary does not know."
  @spec render(term()) :: String.t() | nil
  # A runner's own wire answer, already rendered on the other side; it is
  # no refusal term, so the table does not read it.
  def render(%{"type" => type, "message" => message})
      when is_binary(type) and is_binary(message),
      do: message

  # Everything else is the table's: a guest error, a failure sentence, a
  # setup signal, a refusal of the one vocabulary — and a bare sentence,
  # which the table renders as its own words.
  def render(reason) do
    if is_binary(reason) or Prima.Refusal.reason?(reason), do: Prima.Refusal.message(reason)
  end
end
