defmodule Membrane.RTCP.FeedbackPacket.TWCC do
  # TODO: mock module, to be implemented

  @behaviour Membrane.RTCP.FeedbackPacket

  defstruct []

  @impl true
  def decode(_binary) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def encode(_packet) do
    <<>>
  end
end
