defmodule Membrane.RTP.SessionBin.RTXInfo do
  @moduledoc """
  A struct used to inform SessionBin about availability of RTX stream
  with data allowing to set up proper part of a pipeline
  """
  @enforce_keys [:ssrc, :rtx_payload_type, :original_ssrc, :original_payload_type]
  defstruct @enforce_keys ++ [:rid_id, :repaired_rid_id]
end
