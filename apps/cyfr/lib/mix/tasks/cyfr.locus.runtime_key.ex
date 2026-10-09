# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.RuntimeKey do
  @shortdoc "Print a worker service's key, derived from CYFR_LOCUS_RUNTIME_ROOT"

  @moduledoc """
  Prints the key of one worker service for its operator to configure it
  with: `LOCUS_RUNTIME_KEY=<64 hex>`, the `Prima.WorkerAuth.worker_key/2` of
  the service id, derived from the root in `CYFR_LOCUS_RUNTIME_ROOT`.

      CYFR_LOCUS_RUNTIME_ROOT=… mix cyfr.locus.runtime_key wrk_locus

  The root never leaves CYFR; the service key is the one secret the
  worker service holds, from which its dispatch and dispatch seal keys
  derive. A missing or malformed root (it is 64 hexadecimal digits), or a
  service id that is not a key field (1 to 256 printable ASCII characters
  without spaces), is refused and nothing is printed.
  """

  use Boundary, classify_to: Cyfr.Mix

  use Mix.Task

  alias Prima.WorkerAuth

  @impl Mix.Task
  def run([service_id]) do
    with {:ok, root} <- root(System.get_env("CYFR_LOCUS_RUNTIME_ROOT")),
         {:ok, worker_key} <- worker_key(root, service_id) do
      Mix.shell().info("LOCUS_RUNTIME_KEY=" <> Base.encode16(worker_key, case: :lower))
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("usage: mix cyfr.locus.runtime_key <service_id>")

  defp root(nil), do: {:error, "CYFR_LOCUS_RUNTIME_ROOT is not set"}

  defp root(text) do
    case WorkerAuth.decode_root(text) do
      {:ok, root} -> {:ok, root}
      :error -> {:error, "CYFR_LOCUS_RUNTIME_ROOT is not 64 hexadecimal digits"}
    end
  end

  defp worker_key(root, service_id) do
    case WorkerAuth.worker_key(root, service_id) do
      {:ok, worker_key} ->
        {:ok, worker_key}

      {:error, {:invalid_field, :service}} ->
        {:error, "#{inspect(service_id)} is not a service id"}
    end
  end
end
