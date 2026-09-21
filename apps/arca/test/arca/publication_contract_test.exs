# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PublicationContractTest do
  @moduledoc """
  `Arca.PublicationContract` on the two adapters every run has: the
  double, which is an object store's shape (conditional writes, a
  versioned read, a prefix listing, no tree swap), and Local, which
  swaps the served tree. `publication_contract_s3_test.exs` runs the
  same body against a real S3-compatible store.
  """

  use Arca.PublicationContract,
    adapters: [
      %{adapter: Arca.PublicationContract.Double},
      %{adapter: Arca.Adapters.Local}
    ]
end
