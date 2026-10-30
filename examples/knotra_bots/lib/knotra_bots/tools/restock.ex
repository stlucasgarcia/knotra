defmodule KnotraBots.Tools.Restock do
  @moduledoc """
  Approval-gated restock request for one SKU.

  `read_only: false` makes this a consequential proposal: a human approves the
  quantity before the demo appends it to the effects ledger. Inventory counts are
  not mutated; the point is the approval gate and the visible proposal, not a
  miniature ERP.
  """

  @behaviour Knotra.Tool

  alias KnotraBots.Commerce

  @impl true
  def definition do
    %{
      name: "restock",
      description: "Request a supplier restock for one SKU (mock ledger effect)",
      read_only: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "sku" => %{"type" => "string"},
          "quantity" => %{"type" => "integer"}
        },
        "required" => ["sku", "quantity"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def validate(%{"sku" => sku, "quantity" => quantity} = args)
      when is_binary(sku) and sku != "" and is_integer(quantity) and quantity > 0 and
             quantity <= 500 and map_size(args) == 2 do
    if Commerce.sku?(sku), do: {:ok, args}, else: {:error, :unknown_sku}
  end

  def validate(_args), do: {:error, :invalid_arguments}

  @impl true
  def authorize(_args, %{tenant: tenant}) do
    if tenant == KnotraBots.tenant(), do: :ok, else: {:error, :forbidden}
  end

  @impl true
  def call(%{"sku" => sku, "quantity" => quantity}, _scope) do
    sku = String.downcase(String.trim(sku))
    product = Commerce.product(sku)

    append("restock #{sku} +#{quantity}")

    {:ok,
     "Restock request: #{sku} #{product.name} +#{quantity} " <>
       "(#{product.supplier}, #{product.lead_days}-day lead)."}
  end

  defp append(line) do
    path = KnotraBots.effects_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, line <> "\n", [:append])
  end
end
