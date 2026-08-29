# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UnauthorizedError do
  @moduledoc """
  The raised form of a `Sanctum.Unauthorized` refusal.

  Two control-flow shapes, one vocabulary. Most gates refuse with
  `{:error, reason}`; the `!` accessors (`Sanctum.Context.require_tenant!/1`,
  `athanor!/1`) have no tuple to return and raise instead. What raised used
  to carry its own words — "Unauthorized for action: athanor_required" —
  so the same refusal read one way when returned and another when raised,
  and a surface that rescued it had nothing to branch on but the prose.

  It now carries the reason itself: `Sanctum.Unauthorized.message/2` writes
  the sentence and `code/1` maps it to a JSON-RPC code, exactly as for the
  returned form.

  Carries a `Plug.Exception` status of 403, so a raise that escapes to the
  endpoint renders as the authorization refusal it is — never a 500.
  """

  defexception [:reason, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    opts |> Keyword.get(:reason, :unauthenticated) |> build()
  end

  def exception(reason), do: build(reason)

  defp build(reason) do
    message =
      if Sanctum.Unauthorized.reason?(reason),
        do: Sanctum.Unauthorized.message(reason),
        else: "Unauthorized"

    %__MODULE__{reason: reason, message: message}
  end
end

defimpl Plug.Exception, for: Sanctum.UnauthorizedError do
  def status(_exception), do: 403
  def actions(_exception), do: []
end
