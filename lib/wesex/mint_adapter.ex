defmodule Wesex.MintAdapter do
  @behaviour Wesex.Adapter

  defdelegate encode(websocket, frame), to: Mint.WebSocket

  defdelegate decode(websocket, data), to: Mint.WebSocket

  defdelegate stream_request_body(
                con,
                ref,
                data
              ),
              to: Mint.WebSocket

  defdelegate stream(con, msg), to: Mint.WebSocket

  defdelegate open?(con, mode), to: Mint.HTTP

  defdelegate connect(scheme, addr, port, opts), to: Mint.HTTP

  defdelegate close(con), to: Mint.HTTP

  defdelegate upgrade(
                scheme,
                con,
                path,
                headers,
                opts
              ),
              to: Mint.WebSocket

  defdelegate new(
                con,
                reference,
                response_status,
                response_headers,
                opts
              ),
              to: Mint.WebSocket
end
