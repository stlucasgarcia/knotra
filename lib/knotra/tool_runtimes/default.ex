defmodule Knotra.ToolRuntimes.Default do
  @moduledoc """
  Default tool execution boundary: host argument validation, authorization, then
  execution. This milestone accepts only declared read-only tools; that restriction
  is policy, not a sandbox or a separate execution mechanism.
  """
  @behaviour Knotra.ToolRuntime

  @impl true
  def execute(%{name: name, arguments: args}, tools, auth, _opts) do
    case Enum.find(tools, &(&1.definition().name == name)) do
      nil ->
        {:error, :unknown_tool}

      module ->
        definition = module.definition()

        with true <- definition.read_only,
             true <- is_map(args),
             {:ok, validated} when is_map(validated) <- module.validate(args),
             :ok <- module.authorize(validated, auth) do
          module.call(validated, auth)
        else
          false -> {:error, :write_tool_not_supported}
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :invalid_arguments}
        end
    end
  end

  @doc false
  def schema(definition) do
    ReqLLM.Tool.new(
      name: definition.name,
      description: definition.description,
      parameter_schema: definition.parameters,
      callback: fn _ -> {:error, :use_knotra_tool_runtime} end
    )
  end
end
