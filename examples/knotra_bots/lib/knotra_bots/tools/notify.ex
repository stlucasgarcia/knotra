defmodule KnotraBots.Tools.Notify do
  @moduledoc """
  The approval-gated demonstration effect.

  `read_only: false` marks this as a consequential proposal, so a durable run can
  only execute it after a bound approval, a fresh authorization check and explicit
  inclusion in the instance's `demo_tools` allowlist. It appends one line to a
  local file and performs no network or real messaging effect.
  """

  @behaviour Knotra.Tool

  @impl true
  def definition do
    %{
      name: "notify",
      description: "Queue an internal notice (fake effect; no network)",
      read_only: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to" => %{"type" => "string"},
          "message" => %{"type" => "string"}
        },
        "required" => ["to", "message"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"to" => to, "message" => message} = args)
      when is_binary(to) and to != "" and is_binary(message) and message != "" and
             map_size(args) == 2,
      do: {:ok, args}

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, %{tenant: tenant}) do
    if tenant == KnotraBots.tenant(), do: :ok, else: {:error, :forbidden}
  end

  @impl true
  def call(%{"to" => to}, _scope) do
    path = KnotraBots.notices_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{to}\n", [:append])
    {:ok, "notice queued: #{to}"}
  end
end
