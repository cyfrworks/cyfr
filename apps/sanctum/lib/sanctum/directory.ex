# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory do
  @moduledoc """
  The directory's decisions over the identity logs it orders
  (`Arca.IdentityLog`): registering a genesis, appending a rotation
  against the head it names, applying a recovery against the current
  policy revision, and answering a log, its verified head and a recorded
  request's outcome. A mirror serves history and accepts no write.

  It holds no function yet: this node serves no directory.
  """
end
