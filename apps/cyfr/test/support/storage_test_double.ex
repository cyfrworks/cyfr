# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage.TestDouble do
  @moduledoc """
  A compiler-checked storage-adapter double: `use` it and override only
  the callbacks the test bends — everything else delegates to the Local
  adapter, with the behaviour declared, so a change to the
  `Arca.Storage` contract breaks these doubles at compile time instead
  of letting them drift (three hand-copied doubles once delegated
  `serve_to_conn` with an argument order the behaviour does not have).

      defmodule UnreadableAdapter do
        use Arca.Storage.TestDouble

        def usage(_ctx, _path), do: {:error, :eacces}
      end
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Arca.Storage

      defdelegate get(ctx, path), to: Arca.Adapters.Local
      defdelegate put(ctx, path, content), to: Arca.Adapters.Local
      defdelegate append(ctx, path, content), to: Arca.Adapters.Local
      defdelegate delete(ctx, path), to: Arca.Adapters.Local
      defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
      defdelegate exists?(ctx, path), to: Arca.Adapters.Local
      defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
      defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
      defdelegate usage(ctx, path), to: Arca.Adapters.Local
      defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

      defoverridable get: 2,
                     put: 3,
                     append: 3,
                     delete: 2,
                     list_typed: 2,
                     exists?: 2,
                     delete_tree: 2,
                     list_recursive: 2,
                     usage: 2,
                     serve_to_conn: 4
    end
  end
end
