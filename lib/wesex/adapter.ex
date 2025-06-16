defmodule Wesex.Adapter do
  @moduledoc """
  The behaviour for the connection adapter for `Wesex.Connection`.
  """

  @type state :: any

  @type adapter_result ::
          :handshake_complete
          | {:ping | :pong, nil | binary()}
          | {:text | :binary, binary()}
          | {:close, 1000..4999 | nil, binary() | nil}
          | :tcp_close

  @callback connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
              {:ok, state()} | {:error, reason :: any}
  @callback event(raw_event :: any, state()) :: {[adapter_result], state()} | false
  @callback send_pong(binary(), state) :: {[adapter_result], state()}
  @callback send_ping(state) :: {[adapter_result], state()}
  @callback local_close(code_reason :: {1000..4999, nil | binary()}, state()) ::
              {[adapter_result], state()}
  @callback abort(state) :: {[adapter_result], state()}
  @callback send(message :: {:text | :binary, binary()}, state()) ::
              {:ok, [adapter_result], state()}
              | {:error, [adapter_result], state(), reason :: any}
end
