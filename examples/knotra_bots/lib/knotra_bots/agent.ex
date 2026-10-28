defmodule KnotraBots.Agent do
  @moduledoc """
  Host-owned agent row: name, mention handle, system prompt, model and tools.

  `handle` is the `@mention` humans and other agents use. `revision` bumps on
  every edit, so a durable definition version changes whenever behavior does.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "agents" do
    field(:name, :string)
    field(:handle, :string)
    field(:system_prompt, :string, default: "")
    field(:model, :string)
    field(:tools, :string, default: "")
    field(:revision, :integer, default: 1)
    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :handle, :system_prompt, :model, :tools])
    |> put_handle()
    |> validate_required([:name, :handle, :model])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:handle, min: 2, max: 32)
    |> validate_format(:handle, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase letters, digits, '-' or '_'"
    )
    |> validate_inclusion(:model, KnotraBots.catalog(), message: "is not in the model catalog")
    |> validate_tools()
    |> unique_constraint(:name)
    |> unique_constraint(:handle)
  end

  @doc "The handle form of a name or handle; also used by the changeset."
  def slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 32)
  end

  defp put_handle(changeset) do
    case get_field(changeset, :handle) do
      handle when is_binary(handle) and handle != "" ->
        put_change(changeset, :handle, slug(handle))

      _ ->
        case get_field(changeset, :name) do
          name when is_binary(name) and name != "" -> put_change(changeset, :handle, slug(name))
          _ -> changeset
        end
    end
  end

  defp validate_tools(changeset) do
    case get_field(changeset, :tools) do
      nil ->
        changeset

      tools ->
        names = tools |> String.split(",", trim: true) |> Enum.uniq()

        if Enum.all?(names, &(&1 in KnotraBots.Agents.tool_names())) do
          put_change(changeset, :tools, Enum.join(names, ","))
        else
          add_error(
            changeset,
            :tools,
            "must be a subset of #{Enum.join(KnotraBots.Agents.tool_names(), ", ")}"
          )
        end
    end
  end
end
