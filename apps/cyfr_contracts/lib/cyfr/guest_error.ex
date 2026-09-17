# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GuestError do
  @moduledoc """
  The sentence a runner hands its guest for a refusal, rendered from data
  alone. A refusal reaches a runner over the wire as an answer
  (`Cyfr.WorkerWire`): a guest error's `type` and `message`, a `failed`
  message, a `setup_required` payload, or a refusal name. This renders
  those, the `Cyfr.HostAPI` tuples a host client answers them as, and the
  reasons a runner produces itself. Nothing here names a product module:
  a sentence CYFR wants a guest to see crosses the wire already rendered.

  `render/1` answers `nil` for a term it does not know, so a caller logs
  the term where it was produced and hands the guest a generic sentence
  instead of `inspect/1`'s spelling of it.
  """

  # Tags whose second element is a client-safe sentence by construction:
  # the tuple carries only what its producer already chose to say.
  @sentence_tags [
    :invalid_argument,
    :conflict,
    :crashed,
    :exit,
    :timeout,
    :uncertain,
    :result_lost,
    :not_recorded,
    :failed
  ]

  @doc "The client-safe sentence for `reason`, or `nil` for a term this vocabulary does not know."
  @spec render(term()) :: String.t() | nil
  def render(reason) when is_binary(reason), do: reason

  def render(reason) when is_atom(reason) and not is_nil(reason) and not is_boolean(reason),
    do: Atom.to_string(reason)

  def render(%{"type" => type, "message" => message})
      when is_binary(type) and is_binary(message),
      do: message

  def render({:guest_error, type, message}) when is_binary(type) and is_binary(message),
    do: message

  def render({:guest_error, type, message, %{} = _remediation})
      when is_binary(type) and is_binary(message),
      do: message

  def render({:setup_required, %{} = _payload}),
    do: "The call needs setup before it can run"

  def render({:not_found, resource, id}) when is_binary(resource) and is_binary(id),
    do: "#{resource} not found: #{id}"

  def render({:unavailable, what}) when is_binary(what),
    do: "#{what} is unavailable — retry shortly"

  def render({:corrupt, what}) when is_binary(what),
    do: "#{what} does not match its recorded digest and was not served"

  def render({tag, message}) when tag in @sentence_tags and is_binary(message), do: message

  def render(_reason), do: nil
end
