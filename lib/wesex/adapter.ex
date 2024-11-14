defmodule Wesex.Adapter do
  alias Wesex.Connection

  @type state :: any

  @callback connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
              {:ok, state()} | {:error, reason :: any}
  @callback event(state, raw_event :: any) :: {:event, [Connection.event()]} | false
  @callback send_pong(state, binary()) :: {state(), [Connection.event()]}
  @callback send_ping(state) :: {state(), [Connection.event()]}
  @callback local_close(state, code_reason :: {1000..4999, nil | binary()}) ::
              {state(), [Connection.event()]}
  @callback abort(state) :: {state(), [Connection.event()]}
  @callback send(state, message :: {:text | :binary, binary()}) ::
              {:ok, state, [Connection.event()]}
              | {:error, state, [Connection.event()], reason :: any}
end
