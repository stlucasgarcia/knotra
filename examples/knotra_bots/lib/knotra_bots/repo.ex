defmodule KnotraBots.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :knotra_bots, adapter: Ecto.Adapters.SQLite3
end
