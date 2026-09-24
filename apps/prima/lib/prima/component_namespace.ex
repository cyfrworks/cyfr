# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentNamespace do
  @moduledoc """
  The `local`-namespace rule a storage write into `components/` obeys,
  shared by the two doors that write there: the guest storage boundary
  and the athanor's files.

  A pulled component is fork-to-modify, never rewritten in place: the
  registry would refuse to re-register the rewrite and the digest checks
  would refuse to run the bytes, so the write could only brick the
  component against its row. Only the `local` publisher's units take
  writes, and the refusal names the fork path instead.

  The refusal is a reason (`:not_local_namespace`) and its sentence is
  `message/2`, so every door that refuses says the same words. The other
  namespace refusals (pull, register, fork, build) are the component
  domain's.
  """

  @typedoc "Why a write into a component unit was refused."
  @type refusal :: :not_local_namespace

  @doc """
  Whether a write may land in a unit under `publisher`: only the `local`
  publisher's (`Prima.ComponentPath.local_publisher?/1`).

  ## Examples

      iex> Prima.ComponentNamespace.require_local_guest_write("local")
      :ok

      iex> Prima.ComponentNamespace.require_local_guest_write("acme")
      {:error, :not_local_namespace}
  """
  @spec require_local_guest_write(String.t() | nil) :: :ok | {:error, refusal()}
  def require_local_guest_write(publisher) do
    if Prima.ComponentPath.local_publisher?(publisher),
      do: :ok,
      else: {:error, :not_local_namespace}
  end

  @doc "The sentence a refusal reads as, naming the publisher it refused."
  @spec message(refusal(), String.t() | nil) :: String.t()
  def message(:not_local_namespace, publisher) do
    "Components under '#{publisher}/' are pulled from the registry and " <>
      "never modified in place — fork into local/ to make changes."
  end
end
