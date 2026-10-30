defmodule KnotraBots.Tools.ReturnPolicy do
  @moduledoc """
  Read-only return-eligibility check for one order.

  Reads the order's delivery state and age against the demo's 30-day window. It
  never creates a return or a refund; `KnotraBots.Tools.Refund` is the separate,
  approval-gated write.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "return_policy",
      description: "Check whether an order is return-eligible and the refund amount (read-only)",
      read_only: true,
      parameters: %{
        "type" => "object",
        "properties" => %{"order" => %{"type" => "string"}},
        "required" => ["order"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"order" => order} = args)
      when is_binary(order) and order != "" and map_size(args) == 1,
      do: {:ok, args}

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, %{tenant: tenant}) do
    if tenant == KnotraBots.tenant(), do: :ok, else: {:error, :forbidden}
  end

  @impl true
  def call(%{"order" => order}, _scope) do
    if Commerce.order?(order) do
      {:ok, Commerce.return_summary(order)}
    else
      {:ok, "No order matches #{inspect(order)}."}
    end
  end
end
