# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage.TestDouble do
  @moduledoc """
  A compiler-checked storage-adapter double: `use` it and override only
  the callbacks the test bends — everything else delegates to the Local
  adapter, with the behaviour declared, so a change to the
  `Arca.Storage` contract breaks these doubles at compile time.

      defmodule UnreadableAdapter do
        use Arca.Storage.TestDouble

        def usage(_ctx, _path), do: {:error, :eacces}
      end

  The conditional writes, the versioned read and the prefix listing are
  implemented here over the double's own `exists?/2`, `get/2`, `put/3`
  and `list_recursive/2` — so an override of those bends these too —
  rather than delegating, which is what makes this double an object
  store's shape: a create fails when the object exists, a conditional put
  fails when the precondition (the SHA-256 of the bytes the caller last
  saw) no longer matches, and the check and the write are one step per
  path on this node (`:global.trans/2`), so two writers racing on one key
  get the answers the contract promises.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Arca.Storage

      defdelegate get(actor, path), to: Arca.Adapters.Local
      defdelegate put(actor, path, content), to: Arca.Adapters.Local
      defdelegate append(actor, path, content), to: Arca.Adapters.Local
      defdelegate delete(actor, path), to: Arca.Adapters.Local
      defdelegate list_typed(actor, path), to: Arca.Adapters.Local
      defdelegate exists?(actor, path), to: Arca.Adapters.Local
      defdelegate delete_tree(actor, path), to: Arca.Adapters.Local
      defdelegate list_recursive(actor, path), to: Arca.Adapters.Local
      defdelegate usage(actor, path), to: Arca.Adapters.Local
      defdelegate ensure_dir(actor, path), to: Arca.Adapters.Local
      defdelegate serve_to_conn(conn, actor, path, opts), to: Arca.Adapters.Local

      def put_if_none_match(actor, path, content) do
        bytes = IO.iodata_to_binary(content)

        Arca.Storage.TestDouble.serialized(path, fn ->
          if exists?(actor, path) do
            {:error, :exists}
          else
            with :ok <- put(actor, path, bytes),
                 do: {:ok, Arca.Storage.TestDouble.precondition(bytes)}
          end
        end)
      end

      def put_if_match(actor, path, content, precondition) do
        bytes = IO.iodata_to_binary(content)

        Arca.Storage.TestDouble.serialized(path, fn ->
          case get(actor, path) do
            {:ok, current} ->
              if Arca.Storage.TestDouble.precondition(current) == precondition do
                with :ok <- put(actor, path, bytes),
                     do: {:ok, Arca.Storage.TestDouble.precondition(bytes)}
              else
                {:error, :precondition_failed}
              end

            {:error, :not_found} ->
              {:error, :missing}

            {:error, _reason} = error ->
              error
          end
        end)
      end

      def get_for_update(actor, path) do
        with {:ok, bytes} <- get(actor, path),
             do: {:ok, bytes, Arca.Storage.TestDouble.precondition(bytes)}
      end

      # A listing or an error passes through; only an empty listing asks
      # whether the prefix is itself one object.
      def list_prefix(actor, prefix) do
        with {:ok, []} <- list_recursive(actor, prefix) do
          if exists?(actor, prefix), do: {:ok, [prefix]}, else: {:ok, []}
        end
      end

      defoverridable get: 2,
                     put: 3,
                     append: 3,
                     delete: 2,
                     list_typed: 2,
                     exists?: 2,
                     delete_tree: 2,
                     list_recursive: 2,
                     usage: 2,
                     serve_to_conn: 4,
                     put_if_none_match: 3,
                     put_if_match: 4,
                     get_for_update: 2,
                     list_prefix: 2
    end
  end

  @doc "The double's precondition: the SHA-256 of the object's bytes."
  @spec precondition(binary()) :: String.t()
  def precondition(bytes) when is_binary(bytes), do: Prima.Digest.sha256_hex(bytes)

  @doc """
  Run `fun` as the one conditional write in flight at `path` on this
  node, so its check and its write cannot interleave with another's.
  """
  @spec serialized(Arca.Storage.path(), (-> result)) :: result when result: term()
  def serialized(path, fun) when is_list(path) and is_function(fun, 0) do
    :global.trans({{__MODULE__, path}, self()}, fun, [node()])
  end
end
