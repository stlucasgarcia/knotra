defmodule KnotraBots.Bots do
  @moduledoc """
  Code-defined bot definitions.

  Change a version string whenever prompts, tools or semantic options change:
  durable submissions pin the version and composition for compatibility checks.

  - `:assistant` offers only the read-only `lookup` tool.
  - `:concierge` additionally offers the approval-gated `notify` fake effect.
  """

  alias KnotraBots.Tools

  @versions %{"assistant-v1" => :assistant, "concierge-v1" => :concierge}

  def definition(kind, owner, _opts \\ [])

  def definition(:assistant, owner, _opts),
    do: build("assistant-v1", [Tools.Lookup], owner)

  def definition(:concierge, owner, _opts),
    do: build("concierge-v1", [Tools.Lookup, Tools.Notify], owner)

  @doc "Maps a snapshot's `definition_version` back to a bot kind for rebuilding."
  def kind_for_version(version), do: Map.get(@versions, version)

  defp build(version, tools, owner) do
    %Knotra.Definition{
      version: version,
      model: KnotraBots.model(),
      tools: tools,
      observer: {Knotra.Observers.Send, owner}
    }
  end
end
