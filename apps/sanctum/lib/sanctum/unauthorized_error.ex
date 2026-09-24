# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UnauthorizedError do
  @moduledoc """
  The raised form of a `Sanctum.Unauthorized` refusal.

  Carries `Sanctum.Unauthorized` reasons as exceptions for raising
  accessors such as `Sanctum.Context.require_tenant!/1` and `athanor!/1`.
  Returned and raised refusals share the same reason vocabulary.

  It carries the reason itself: `Sanctum.Unauthorized.message/2` writes
  the sentence and `class/1` places it, exactly as for the returned form.

  Its `Plug.Exception` status is 401 for a reason of class
  `unauthenticated` and 403 for every other, so a raise that escapes to
  the endpoint renders as the authorization refusal it is — never a 500.
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
  def status(%{reason: reason}) do
    if Sanctum.Unauthorized.reason?(reason) and
         Sanctum.Unauthorized.class(reason) == :unauthenticated,
       do: 401,
       else: 403
  end

  def actions(_exception), do: []
end
