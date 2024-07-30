defmodule Wesex.Websocket.Closing do
  @moduledoc false
  # The client has sent a close frame, and waiting for the server reply.

  alias Wesex.Websocket.{Open, Closed}
  alias Mint.HTTP
  import Wesex.Utils

  @close_timeout 5000
  @type t :: %__MODULE__{
          con: Mint.HTTP.t(),
          ws: Mint.WebSocket.t(),
          ws_ref: Mint.Types.request_ref(),
          close_timer: reference(),
          remote_close_reason: nil | Wesex.Websocket.close_reason(),
          initiator: :local | :remote
        }

  @enforce_keys [:con, :ws, :ws_ref, :close_timer, :initiator]
  defstruct [:con, :ws, :ws_ref, :close_timer, :initiator, remote_close_reason: nil]

  @doc """
  New closing state from `Open`. Flush-cancels timer, sets new timer, does not send close frame.
  If `Closing` was given, return as is.

  Timeout message is `{:close_timeout, ws_ref}`
  """
  def new(open_or_closing, initiator, close_timeout \\ @close_timeout, timer_dest \\ :self)

  def new(
        %Open{con: con, ping_timer: ping_timer, ws: ws, ws_ref: ws_ref},
        initiator,
        close_timeout,
        timer_dest
      ) do
    _ = flush_timer(ping_timer, {:ping_time, ^ws_ref})

    dest = if timer_dest == :self, do: self(), else: timer_dest
    close_timer = Process.send_after(dest, {:close_timeout, ws_ref}, close_timeout)
    %__MODULE__{close_timer: close_timer, con: con, ws: ws, ws_ref: ws_ref, initiator: initiator}
  end

  @doc """
  Closes the connection, flush-cancels the timer.
  """
  def fail(%__MODULE__{close_timer: close_timer, ws_ref: ws_ref, con: con}) do
    {:ok, _} = HTTP.close(con)
    _ = flush_timer(close_timer, {:close_timeout, ^ws_ref})
    %Closed{}
  end
end
