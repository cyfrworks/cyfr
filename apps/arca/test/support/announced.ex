# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Announced do
  @moduledoc """
  Tells the test that attached it each path one athanor's change
  announces (`Arca.ObjectRevisions.announce/2`), as
  `{:announced, path, in_transaction?, settled?}`: whether a transaction
  was still open when it was announced, and whether a reader then reads
  a settled file at the path.
  """

  @doc "Attach under `id` for `actor`'s athanor; the caller detaches `id` on exit."
  @spec attach(term(), Prima.Actor.t()) :: :ok | {:error, :already_exists}
  def attach(id, %Prima.Actor{} = actor),
    do:
      :telemetry.attach(
        id,
        [:cyfr, :arca, :file, :changed],
        &__MODULE__.handle/4,
        {self(), actor}
      )

  @doc false
  def handle(_event, _measurements, %{athanor_id: athanor_id, path: path}, {pid, actor})
      when athanor_id == actor.athanor_id do
    settled = match?({:ok, _}, Arca.ObjectRevisions.changed_at(actor, String.split(path, "/")))
    send(pid, {:announced, path, Arca.in_transaction?(), settled})
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
