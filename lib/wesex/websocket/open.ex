defmodule Wesex.Websocket.Open do
  @moduledoc false
  # The websocket connection is ready to send and receive data.

  import Wesex.Utils, only: [flush_timer: 2]
  alias Wesex.Websocket.{Closed}
  alias Mint.HTTP
  @ping_intv 10_000

  @type data_frame :: {:text, String.t()} | {:binary, binary()}

  @type t :: %__MODULE__{
          con: Mint.HTTP.t(),
          ws: Mint.WebSocket.t(),
          ws_ref: Mint.Types.request_ref(),
          ponged: boolean(),
          ping_timer: reference(),
          ping_intv: pos_integer()
        }

  @type close_reason :: %{optional(:reason) => String.t(), code: nil | pos_integer}

  @enforce_keys [:con, :ws, :ws_ref, :ping_timer, :ponged]
  defstruct [:con, :ws, :ws_ref, :ping_timer, ponged: true, ping_intv: @ping_intv]

  def default_ping_intv, do: @ping_intv

  @doc """
  Closes the connection, flush-cancels the timer.
  """
  def fail(%__MODULE__{ping_timer: ping_timer, ws_ref: ws_ref, con: con}) do
    {:ok, _} = HTTP.close(con)
    _ = flush_timer(ping_timer, {:ping_time, ^ws_ref})
    %Closed{}
  end
end
