defmodule KnotraBots.Bot do
  @moduledoc """
  Host-owned bot row: name, system prompt, model string and allowed tools.

  `tools` is a comma-joined subset of the host tool names; `revision` is bumped on
  every edit so a bot's durable definition version changes when its behavior does.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "bots" do
    field(:name, :string)
    field(:system_prompt, :string, default: "")
    field(:model, :string)
    field(:tools, :string, default: "")
    field(:revision, :integer, default: 1)
    timestamps()
  end

  def changeset(bot, attrs) do
    bot
    |> cast(attrs, [:name, :system_prompt, :model, :tools])
    |> validate_required([:name, :model])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:model, KnotraBots.catalog(), message: "is not in the model catalog")
    |> validate_tools()
    |> unique_constraint(:name)
  end

  defp validate_tools(changeset) do
    case get_field(changeset, :tools) do
      nil ->
        changeset

      tools ->
        names = tools |> String.split(",", trim: true) |> Enum.uniq()

        if Enum.all?(names, &(&1 in KnotraBots.Bots.tool_names())) do
          put_change(changeset, :tools, Enum.join(names, ","))
        else
          add_error(
            changeset,
            :tools,
            "must be a subset of #{Enum.join(KnotraBots.Bots.tool_names(), ", ")}"
          )
        end
    end
  end
end
